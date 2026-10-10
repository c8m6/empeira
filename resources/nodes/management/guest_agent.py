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


def terminate():
    global active
    if not active:
        return
    if active['kind'] == 'exec':
        process = active['process']
        # The unreaped session leader pins the PID/process-group until cleanup.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
            if sig == signal.SIGTERM:
                time.sleep(0.1)
        process.wait()
        for pipe in active['pipes']:
            if pipe.closed:
                continue
            try:
                events.unregister(pipe.fileno())
            except (FileNotFoundError, OSError):
                pass
            pipe.close()
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
              'open': pipes, 'deadline': time.monotonic() + message['timeout']}
    for pipe in pipes:
        os.set_blocking(pipe, False)
        events.register(pipe, select.EPOLLIN | select.EPOLLHUP)
    send({'type': 'started'})


def handle(message):
    global active, request_id
    kind = message['type']
    if kind == 'hello':
        if message.get('token') != TOKEN:
            raise ValueError('Instance identity mismatch')
        if active:
            terminate()
        request_id = message['id']
        send({'type': 'hello', 'token': TOKEN, 'version': 1})
        return
    if message['id'] != request_id:
        raise ValueError('Request identity mismatch')
    if kind == 'cancel':
        terminate()
        send({'type': 'exit', 'status': 130, 'timed_out': False})
    elif kind == 'exec' and active is None:
        timeout = message['timeout']
        if not isinstance(timeout, (int, float)) or not 0 < timeout <= 86400:
            raise ValueError('Invalid operation timeout')
        start_exec(message)
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
    data = os.read(pipe, CHUNK)
    if data:
        send({'type': kind, 'data': base64.b64encode(data).decode()})
    else:
        events.unregister(pipe)
        del active['open'][pipe]
        stream.close()


try:
    while True:
        timeout = -1 if not active else max(0, min(0.1, active['deadline'] - time.monotonic()))
        for device, flags in events.poll(timeout):
            if device == fd:
                serial_input()
            elif active and active['kind'] == 'exec' and device in active['open']:
                output(device)
        if active and time.monotonic() >= active['deadline']:
            terminate()
            send({'type': 'exit', 'status': None, 'timed_out': True})
        elif (active and active['kind'] == 'exec' and not active['open'] and
              os.waitid(os.P_PID, active['process'].pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)):
            # wait() reaps only after every output pipe reaches EOF; no PID reuse while cancelling.
            try:
                os.killpg(active['process'].pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
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
