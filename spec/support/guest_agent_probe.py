# SPDX-License-Identifier: AGPL-3.0-only
# Protocol-only probe with an isolated synthetic UID boundary; real UID 0 is tested in QEMU.
import atexit,base64,json,os,socket,subprocess,sys,tempfile,time,threading
from pathlib import Path
with tempfile.TemporaryDirectory() as root:
    path=root+'/port.sock'; server=socket.socket(socket.AF_UNIX);server.bind(path);server.listen(1)
    harness="""import os,runpy,socket,sys,stat,pwd,types
sock=socket.socket(socket.AF_UNIX);sock.connect(sys.argv[2]);fd=sock.detach();os.set_blocking(fd,False)
real_open=os.open;os.open=lambda path,*args,**kw: fd if path=='test-port' else real_open(path,*args,**kw)
os.geteuid=lambda:0
source=open(sys.argv[1]).read().replace("ROOT = '/run/empeira-management'", 'ROOT = '+repr(sys.argv[3]))
source=source.replace("SHELL_RC = '/usr/local/libexec/empeira-management-shell-rc'", 'SHELL_RC = '+repr(os.path.join(os.path.dirname(sys.argv[1]), 'shell_rc.sh')))
stage_root=sys.argv[3]
pwd.getpwuid=lambda uid:types.SimpleNamespace(pw_dir=os.path.dirname(stage_root))
os.environ['RUNTIME_DIRECTORY']=stage_root
real_write=os.write
def write(fd_number,data):
 if fd_number==fd and os.path.exists(stage_root+'/force-io-failure'):
  raise OSError(5,'synthetic transport failure')
 return real_write(fd_number,data)
os.write=write
real_lstat=os.lstat
class Metadata:
 st_mode=stat.S_IFDIR|0o700
 st_uid=0
os.lstat=lambda path:Metadata() if path==stage_root else real_lstat(path)
sys.argv=['agent','test-port','synthetic-instance']
exec(compile(source,'guest_agent.py','exec'))
"""
    h=Path(root+'/h.py');h.write_text(harness)
    process=subprocess.Popen([sys.executable,str(h),sys.argv[1],path,root+'/stage'],stderr=None)
    def cleanup():
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill();process.wait()
    atexit.register(cleanup)
    conn,_=server.accept();conn.settimeout(4);reader=conn.makefile('rb'); identity='probe'
    def send(**kw):conn.sendall((json.dumps(dict(id=identity,**kw))+'\n').encode())
    def recv():
        response=json.loads(reader.readline());assert response['id']==identity;return response
    send(type='hello',token='synthetic-instance');assert recv()['type']=='hello'
    send(type='exec',argv=[sys.executable,'-c',"import sys;sys.stdout.write('x'*300000);sys.stderr.write('y'*170000);sys.exit(6)"],timeout=5)
    out=bytearray();err=bytearray()
    while True:
        frame=recv()
        if frame['type']=='stdout':out.extend(base64.b64decode(frame['data']))
        if frame['type']=='stderr':err.extend(base64.b64decode(frame['data']))
        if frame['type']=='exit': assert frame['status']==6;break
    assert len(out)==300000 and len(err)==170000
    send(type='exec',argv=[sys.executable,'-c',"import os;assert 'RUNTIME_DIRECTORY' not in os.environ"],timeout=1)
    assert recv()['type']=='started';assert recv()['status']==0
    send(type='exec',argv=['nonexistent-command'],timeout=1);assert recv()['type']=='stderr';assert recv()['status']==127
    send(type='exec',argv=[sys.executable,'-c','import os,time;os.close(1);os.close(2);time.sleep(30)'],timeout=.2);assert recv()['type']=='started';assert recv()['timed_out']
    send(type='exec',argv=[sys.executable,'-c','import time;time.sleep(30)'],timeout=20);assert recv()['type']=='started';send(type='cancel');assert recv()['status']==130
    import hashlib
    data=os.urandom(300000);send(type='upload');assert recv()['type']=='ready'
    for i in range(0,len(data),16384):send(type='chunk',data=base64.b64encode(data[i:i+16384]).decode());assert recv()['type']=='ready'
    destination=root+'/installed';send(type='install',destination=destination,mode='0600',sha256=hashlib.sha256(data).hexdigest());assert recv()['status']==0
    assert Path(destination).read_bytes()==data and (os.stat(destination).st_mode&0o777)==0o600
    assert list(Path(root+'/stage').iterdir())==[]
    pid_path = root+'/owned-pid'
    send(type='exec',argv=[sys.executable,'-c',"import os,time;open("+repr(pid_path)+",'w').write(str(os.getpid()));time.sleep(30)"],timeout=30)
    assert recv()['type']=='started'
    deadline=time.monotonic()+2
    while not Path(pid_path).exists():
        assert time.monotonic()<deadline
        time.sleep(.01)
    owned_pid=int(Path(pid_path).read_text())
    conn.shutdown(socket.SHUT_RDWR);reader.close();conn.close()
    deadline=time.monotonic()+2
    while True:
        try: os.kill(owned_pid,0)
        except ProcessLookupError: break
        assert time.monotonic()<deadline, 'Disconnected command was not reaped'
        time.sleep(.01)
    assert process.poll() is None, 'Idle adapter must keep waiting without a polling loop'
    process.terminate();process.wait(timeout=5)

    stage_fault=root+'/fault-stage'
    process=subprocess.Popen([sys.executable,str(h),sys.argv[1],path,stage_fault],stderr=None)
    conn,_=server.accept();conn.settimeout(4);reader=conn.makefile('rb')
    send(type='hello',token='synthetic-instance');assert recv()['type']=='hello'
    pid_path=root+'/fault-owned-pid'
    send(type='exec',argv=[sys.executable,'-c',"import os,time;open("+repr(pid_path)+",'w').write(str(os.getpid()));time.sleep(30)"],timeout=30)
    assert recv()['type']=='started'
    deadline=time.monotonic()+2
    while not Path(pid_path).exists():
        assert time.monotonic()<deadline
        time.sleep(.01)
    owned_pid=int(Path(pid_path).read_text())
    Path(stage_fault+'/force-io-failure').touch()
    send(type='cancel')
    assert process.wait(timeout=5)==1, 'Fatal transport I/O must trigger the systemd failure restart policy'
    try: os.kill(owned_pid,0)
    except ProcessLookupError: pass
    else: raise AssertionError('Fatal transport I/O left an owned command alive')
    reader.close();conn.close()

    process=subprocess.Popen([sys.executable,str(h),sys.argv[1],path,root+'/pty-stage'],stderr=None)
    conn,_=server.accept();conn.settimeout(5);reader=conn.makefile('rb')
    send(type='hello',token='synthetic-instance');assert recv()['type']=='hello'
    send(type='shell',size=[27,93],term='xterm-256color')
    output=bytearray();credit=False
    def shell_read(until):
        global credit
        deadline=time.monotonic()+5
        while not until():
            assert time.monotonic()<deadline,bytes(output)
            frame=recv()
            if frame['type']=='ready':credit=True
            elif frame['type']=='stdout':output.extend(base64.b64decode(frame['data']))
            elif frame['type']=='exit':raise AssertionError(('Unexpected shell exit',frame,bytes(output)))
            else:assert frame['type']=='started',frame
    def shell_input(data):
        global credit
        shell_read(lambda:credit)
        send(type='input',data=base64.b64encode(data).decode());credit=False
    def shell_command(command,marker):
        output.clear();shell_input(command.encode()+b'\n')
        shell_read(lambda:marker in output)
    shell_read(lambda:credit)
    shell_command("stty size; printf 'INITIAL_DONE\\n'",b'27 93\r\n')
    send(type='resize',size=[39,111])
    shell_command("stty size; printf 'RESIZE_DONE\\n'",b'39 111\r\n')
    shell_command("printf '\\033[31mCOLOR_OK\\033[0m\\n'",b'\x1b[31mCOLOR_OK\x1b[0m')
    # Use the same guest PTY path as full-screen tools and verify controlling-terminal/job-control semantics.
    shell_command("test -t 0 && test -t 1 && printf 'PTY_%s\\n' VERIFIED",b'PTY_VERIFIED\r\n')
    foreground=root+'/foreground-pid'
    shell_input(("sh -c 'echo $$ > "+foreground+"; exec sleep 30'\n").encode())
    deadline=time.monotonic()+3
    while not Path(foreground).exists():assert time.monotonic()<deadline;time.sleep(.01)
    owned_pid=int(Path(foreground).read_text())
    shell_input(b'\x1a')
    shell_read(lambda:b'Stopped' in output)
    shell_input(b'fg\n');time.sleep(.1);shell_input(b'\x03')
    shell_command("printf 'INT_%s\\n' RECOVERED",b'INT_RECOVERED\r\n')
    try:os.kill(owned_pid,0)
    except ProcessLookupError:pass
    else:raise AssertionError('Foreground process survived Ctrl+C')
    shell_input(b'\x04')
    while True:
        frame=recv()
        if frame['type']=='exit':assert frame['status']==0;break
    # A new session must work after PTY EOF; cancel owns all background process groups.
    send(type='shell',size=[24,80],term='xterm');credit=False;output.clear();shell_read(lambda:credit)
    background=root+'/background-pid'
    shell_input(("sleep 30 & echo $! > "+background+"\n").encode())
    deadline=time.monotonic()+3
    while not Path(background).exists():assert time.monotonic()<deadline;time.sleep(.01)
    owned_pid=int(Path(background).read_text());send(type='cancel')
    while recv()['type']!='exit':pass
    stat_path=Path('/proc/'+str(owned_pid)+'/stat')
    assert not stat_path.exists() or stat_path.read_text().rpartition(') ')[2].startswith('Z '), 'Background job survived shell cancellation'
    reader.close();conn.close();process.terminate();process.wait(timeout=5)
    print('large stdout/stderr, exit 6, missing command, closed-pipe timeout, cancel, disconnect reap, fatal I/O cleanup, binary upload and cleanup passed; PTY, resize, ANSI, Ctrl+C/D/Z, foreground and background cleanup passed')
