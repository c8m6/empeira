#!/usr/bin/python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Private VirtIO-Serial execution adapter; no account authentication or network."""
import base64
import hashlib
import json
import os
import select
import signal
import shutil
import subprocess
import sys
import stat
import tempfile
import time
import errno
import fcntl
import pty
import pwd
import struct
import termios

LIMIT = 131072
CHUNK = 16384
TOKEN = sys.argv[2]
PORT = sys.argv[1]
ROOT = '/run/empeira-management'
os.umask(0o077)
os.makedirs(ROOT, mode=0o700, exist_ok=True)
metadata = os.lstat(ROOT)
if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o077:
    raise RuntimeError('Management staging ownership is invalid')
if os.geteuid() != 0:
    raise RuntimeError('Management requires numeric UID 0')


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


for termination_signal in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(termination_signal, interrupted)


def supervise(ports):
    # Independent bounded workers preserve the existing streaming/atomic-upload protocol.
    # A blocked or failed session cannot stall another channel or ordinary Puppet execution.
    workers = {}
    try:
        while True:
            for port in ports:
                worker = workers.get(port)
                if worker is None or worker.poll() is not None:
                    workers[port] = subprocess.Popen([sys.executable, __file__, port, TOKEN])
            time.sleep(0.5)
    finally:
        for worker in workers.values():
            if worker.poll() is None:
                worker.terminate()
        for worker in workers.values():
            try:
                worker.wait(timeout=3)
            except subprocess.TimeoutExpired:
                worker.kill()
                worker.wait()


if len(sys.argv) > 3:
    supervise([PORT, *sys.argv[3:]])
    raise SystemExit(0)

fd = os.open(PORT, os.O_RDWR | os.O_NONBLOCK)
events = select.epoll()
events.register(fd, select.EPOLLIN | select.EPOLLET | select.EPOLLHUP)
buffer = bytearray()
active = None
request_id = None


def send(data):
    data['id'] = request_id
    raw = (json.dumps(data, separators=(',', ':')) + '\n').encode()
    if len(raw) > LIMIT:
        raise ValueError('Oversized protocol frame')
    deadline = time.monotonic() + 5
    while raw:
        if time.monotonic() >= deadline:
            raise TimeoutError()
        try:
            written = os.write(fd, raw)
            if written <= 0:
                raise EOFError()
            raw = raw[written:]
        except BlockingIOError:
            select.select([], [fd], [], 2)


def session_groups(pid):
    groups = set()
    for entry in os.scandir('/proc'):
        if not entry.name.isdigit():
            continue
        try:
            with open(entry.path + '/stat') as source:
                fields = source.read().rpartition(') ')[2].split()
            if fields[0] != 'Z' and int(fields[3]) == pid:
                groups.add(int(fields[2]))
        except (FileNotFoundError, ProcessLookupError):
            continue
    return groups


def terminate_groups(pid):
    # The unreaped session leader pins the identity even when its shell created job-control groups.
    groups = session_groups(pid)
    if not groups:
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for group in groups:
            try:
                os.killpg(group, sig)
            except ProcessLookupError:
                pass
        if sig == signal.SIGTERM:
            time.sleep(0.1)
            groups = session_groups(pid)


def terminate():
    global active
    if not active:
        return
    if active['kind'] in ('exec', 'shell'):
        process = active['process']
        # The unreaped session leader pins the PID/process-group until cleanup.
        terminate_groups(process.pid)
        process.wait()
        for pipe in active['pipes']:
            if isinstance(pipe, int) and pipe not in active['open']:
                continue
            if not isinstance(pipe, int) and pipe.closed:
                continue
            try:
                events.unregister(pipe if isinstance(pipe, int) else pipe.fileno())
            except (FileNotFoundError, OSError):
                pass
            os.close(pipe) if isinstance(pipe, int) else pipe.close()
    else:
        active['file'].close()
        os.unlink(active['path'])
    active = None


def start_exec(message):
    global active
    argv = message['argv']
    if not isinstance(argv, list) or not argv or not all(isinstance(s, str) and '\0' not in s for s in argv):
        raise ValueError('Invalid command arguments')
    try:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True,
                                   env={**{key: value for key, value in os.environ.items() if key != 'RUNTIME_DIRECTORY'}, 'PATH': '/opt/puppetlabs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'})
    except OSError as error:
        send({'type': 'stderr', 'data': base64.b64encode((os.strerror(error.errno) + '\n').encode()).decode()})
        send({'type': 'exit', 'status': 127 if error.errno == 2 else 126, 'timed_out': False})
        return
    pipes = {process.stdout.fileno(): (process.stdout, 'stdout'),
             process.stderr.fileno(): (process.stderr, 'stderr')}
    active = {'kind': 'exec', 'process': process, 'pipes': [process.stdout, process.stderr],
              'open': pipes, 'deadline': time.monotonic() + message['timeout'] if message['timeout'] else None}
    for pipe in pipes:
        os.set_blocking(pipe, False)
        events.register(pipe, select.EPOLLIN | select.EPOLLHUP)
    send({'type': 'started'})


class ShellProcess:
    def __init__(self, pid):
        self.pid = pid

    def wait(self):
        _, status = os.waitpid(self.pid, 0)
        return os.WEXITSTATUS(status) if os.WIFEXITED(status) else -os.WTERMSIG(status)


def terminal_size(message):
    size = message.get('size')
    if (not isinstance(size, list) or len(size) != 2 or
            not all(type(value) is int and 0 < value <= 65535 for value in size)):
        raise ValueError('Invalid terminal dimensions')
    return struct.pack('HHHH', *size, 0, 0)


def command_environment():
    return {**{key: value for key, value in os.environ.items() if key != 'RUNTIME_DIRECTORY'},
            'PATH': '/opt/puppetlabs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'}


SHELL_RC = '/usr/local/libexec/empeira-management-shell-rc'


def start_shell(message):
    global active
    size = terminal_size(message)
    term = message.get('term', 'xterm')
    if not isinstance(term, str) or not 1 <= len(term) <= 64 or not all(c.isalnum() or c in '-_.+' for c in term):
        raise ValueError('Invalid terminal type')
    shell = shutil.which('bash') or shutil.which('sh')
    if not shell:
        raise ValueError('No guest shell is available')
    pid, master = pty.fork()
    if pid == 0:
        try:
            fcntl.ioctl(0, termios.TIOCSWINSZ, size)
            try:
                home = pwd.getpwuid(0).pw_dir
            except KeyError:
                home = '/'
            os.chdir(home if os.path.isdir(home) else '/')
            arguments = [shell, '--rcfile', SHELL_RC, '-i'] if os.path.basename(shell) == 'bash' else [shell, '-i']
            os.execvpe(shell, arguments, {**command_environment(), 'HOME': home, 'HISTFILE': '/dev/null',
                                        'USER': 'root', 'LOGNAME': 'root', 'TERM': term})
        except Exception:
            os._exit(126)
    os.set_blocking(master, False)
    active = {'kind': 'shell', 'process': ShellProcess(pid), 'pipes': [master],
              'open': {master: (master, 'stdout')}, 'deadline': None,
              'input': bytearray(), 'master': master}
    events.register(master, select.EPOLLIN | select.EPOLLHUP)
    send({'type': 'started'})
    send({'type': 'ready'})


def shell_input(message):
    data = base64.b64decode(message['data'], validate=True)
    if len(data) > CHUNK or active['input']:
        raise ValueError('Shell input exceeds its granted credit')
    active['input'].extend(data)
    events.modify(active['master'], select.EPOLLIN | select.EPOLLOUT | select.EPOLLHUP)


def flush_shell_input():
    master = active['master']
    try:
        written = os.write(master, active['input'])
        del active['input'][:written]
    except BlockingIOError:
        return
    if not active['input']:
        events.modify(master, select.EPOLLIN | select.EPOLLHUP)
        send({'type': 'ready'})


def handle(message):
    global active, request_id
    kind = message['type']
    if kind == 'hello':
        if message.get('token') != TOKEN:
            raise ValueError('Instance identity mismatch')
        if active:
            terminate()
        request_id = message['id']
        send({'type': 'hello', 'token': TOKEN, 'version': 2})
        return
    if message['id'] != request_id:
        raise ValueError('Request identity mismatch')
    if kind == 'cancel':
        terminate()
        send({'type': 'exit', 'status': 130, 'timed_out': False})
    elif kind == 'exec' and active is None:
        timeout = message['timeout']
        if timeout is not None and (type(timeout) not in (int, float) or not 0 < timeout <= 86400):
            raise ValueError('Invalid operation timeout')
        start_exec(message)
    elif kind == 'shell' and active is None:
        start_shell(message)
    elif active and active['kind'] == 'shell' and kind == 'input':
        shell_input(message)
    elif active and active['kind'] == 'shell' and kind == 'resize':
        fcntl.ioctl(active['master'], termios.TIOCSWINSZ, terminal_size(message))
    elif active and active['kind'] == 'shell' and kind == 'eof':
        terminate()
        send({'type': 'exit', 'status': 0, 'timed_out': False})
    elif active and active['kind'] == 'shell' and kind == 'signal':
        allowed = {'INT': signal.SIGINT, 'TERM': signal.SIGTERM, 'HUP': signal.SIGHUP,
                   'TSTP': signal.SIGTSTP, 'CONT': signal.SIGCONT}
        sig = allowed.get(message.get('signal'))
        group = os.tcgetpgrp(active['master'])
        if sig is None or os.getsid(group) != active['process'].pid:
            raise ValueError('Invalid shell foreground signal')
        os.killpg(group, sig)
    elif kind == 'upload' and active is None:
        file = tempfile.NamedTemporaryFile(dir=ROOT, delete=False)
        active = {'kind': 'upload', 'file': file, 'path': file.name, 'digest': hashlib.sha256(),
                  'deadline': time.monotonic() + 120}
        send({'type': 'ready'})
    elif kind == 'chunk' and active and active['kind'] == 'upload':
        data = base64.b64decode(message['data'], validate=True)
        if len(data) > CHUNK:
            raise ValueError('Oversized upload chunk')
        active['file'].write(data)
        active['digest'].update(data)
        active['deadline'] = time.monotonic() + 120
        send({'type': 'ready'})
    elif kind == 'install' and active and active['kind'] == 'upload':
        destination, mode = message['destination'], message['mode']
        if not isinstance(destination, str) or not destination.startswith('/') or '\0' in destination:
            raise ValueError('Invalid destination')
        if not isinstance(mode, str) or len(mode) != 4 or any(c not in '01234567' for c in mode):
            raise ValueError('Invalid mode')
        if active['digest'].hexdigest() != message['sha256']:
            raise ValueError('Upload integrity mismatch')
        active['file'].flush()
        os.fsync(active['file'].fileno())
        staged = active['path']
        active['file'].close()
        active = None
        pending = None
        try:
            with tempfile.NamedTemporaryFile(dir=os.path.dirname(destination), delete=False) as target:
                pending = target.name
                with open(staged, 'rb') as source:
                    shutil.copyfileobj(source, target, CHUNK)
                target.flush()
                os.fchmod(target.fileno(), int(mode, 8))
                os.fsync(target.fileno())
            os.replace(pending, destination)
            pending = None
            send({'type': 'exit', 'status': 0, 'timed_out': False})
        except OSError as error:
            send({'type': 'stderr', 'data': base64.b64encode((os.strerror(error.errno) + '\n').encode()).decode()})
            send({'type': 'exit', 'status': 1, 'timed_out': False})
        finally:
            os.unlink(staged)
            if pending:
                os.unlink(pending)
    else:
        raise ValueError('Unexpected protocol operation')


def serial_input():
    global buffer, request_id
    while True:
        try:
            data = os.read(fd, CHUNK)
        except BlockingIOError:
            return
        if not data:
            terminate()
            buffer.clear()
            request_id = None
            return
        buffer.extend(data)
        if len(buffer) > LIMIT:
            raise ValueError('Oversized input frame')
        while b'\n' in buffer:
            line, _, remaining = buffer.partition(b'\n')
            buffer = bytearray(remaining)
            handle(json.loads(line))


def output(pipe):
    stream, kind = active['open'][pipe]
    try:
        data = os.read(pipe, CHUNK)
    except BlockingIOError:
        return
    except OSError as error:
        if error.errno != errno.EIO or active['kind'] != 'shell':
            raise
        data = b''
    if data:
        send({'type': kind, 'data': base64.b64encode(data).decode()})
    else:
        events.unregister(pipe)
        del active['open'][pipe]
        os.close(stream) if isinstance(stream, int) else stream.close()


try:
    while True:
        timeout = -1 if not active else 0.1
        for device, flags in events.poll(timeout):
            if device == fd:
                serial_input()
            elif active and active['kind'] in ('exec', 'shell') and device in active['open']:
                if flags & (select.EPOLLIN | select.EPOLLHUP):
                    output(device)
                if active and active['kind'] == 'shell' and flags & select.EPOLLOUT and device in active['open']:
                    flush_shell_input()
        if active and active['deadline'] is not None and time.monotonic() >= active['deadline']:
            terminate()
            send({'type': 'exit', 'status': None, 'timed_out': True})
        elif (active and active['kind'] in ('exec', 'shell') and
              os.waitid(os.P_PID, active['process'].pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)):
            # wait() reaps only after every output pipe reaches EOF; no PID reuse while cancelling.
            terminate_groups(active['process'].pid)
            if active['open']:
                continue
            status = active['process'].wait()
            active = None
            send({'type': 'exit', 'status': status if status >= 0 else 128 - status, 'timed_out': False})
except (BrokenPipeError, EOFError, OSError) as error:
    terminate()
    print('Management transport failure: ' + type(error).__name__, file=sys.stderr)
    raise SystemExit(1)
except Exception as error:
    terminate()
    # Never log command arguments, input frames, keys or uploaded content.
    print('Management protocol failure: ' + type(error).__name__, file=sys.stderr)
    raise SystemExit(1)
finally:
    terminate()
    events.close()
    os.close(fd)
