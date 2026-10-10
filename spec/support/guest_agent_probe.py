# SPDX-License-Identifier: AGPL-3.0-only
# Protocol-only probe with an isolated synthetic UID boundary; real UID 0 is tested in QEMU.
import atexit,base64,json,os,socket,subprocess,sys,tempfile,time,threading
from pathlib import Path
with tempfile.TemporaryDirectory() as root:
    path=root+'/port.sock'; server=socket.socket(socket.AF_UNIX);server.bind(path);server.listen(1)
    harness="""import os,runpy,socket,sys,stat
sock=socket.socket(socket.AF_UNIX);sock.connect(sys.argv[2]);fd=sock.detach();os.set_blocking(fd,False)
real_open=os.open;os.open=lambda path,*args,**kw: fd if path=='test-port' else real_open(path,*args,**kw)
os.geteuid=lambda:0
source=open(sys.argv[1]).read().replace("ROOT = '/run/empeira-management'", 'ROOT = '+repr(sys.argv[3]))
stage_root=sys.argv[3]
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

    print('large stdout/stderr, exit 6, missing command, closed-pipe timeout, cancel, disconnect reap, fatal I/O cleanup, binary upload and cleanup passed')
