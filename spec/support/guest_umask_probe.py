# SPDX-License-Identifier: AGPL-3.0-or-later
"""Exercise the real guest command launch functions without Linux VirtIO/epoll."""
import ast
import base64
import fcntl
import os
from pathlib import Path
import pty
import pwd
import select
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import termios
import time
import types

source = ast.parse(Path(sys.argv[1]).read_text())
names = {'start_exec', 'start_shell', 'terminal_size', 'command_environment', 'ShellProcess'}
functions = ast.Module(body=[node for node in source.body
                            if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names],
                       type_ignores=[])
frames = []
send = frames.append
events = types.SimpleNamespace(register=lambda *args: None)
select = types.SimpleNamespace(EPOLLIN=1, EPOLLHUP=16)
active = None
exec(compile(functions, sys.argv[1], 'exec'))

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    stage = root / 'private-stage'
    stage.mkdir(mode=0o700)
    foreign = root / 'foreign.gpg'
    foreign.write_bytes(b'foreign')
    foreign.chmod(0o600)
    os.umask(0o077)
    os.environ['RUNTIME_DIRECTORY'] = str(stage)
    command = """import os, pathlib, tempfile
root = pathlib.Path(__import__('sys').argv[1])
assert 'RUNTIME_DIRECTORY' not in os.environ
keys = root / 'keyrings'
keys.mkdir(exist_ok=True)
(keys / 'owned.gpg').write_bytes(b'public key fixture')
with tempfile.NamedTemporaryFile(dir=root) as private:
    assert os.stat(private.name).st_mode & 0o777 == 0o600
"""
    for _ in range(2):
        start_exec({'argv': [sys.executable, '-c', command, directory], 'timeout': 5})
        output, error = active['process'].communicate(timeout=5)
        assert active['process'].returncode == 0, error
        assert stat.S_IMODE((root / 'keyrings').stat().st_mode) == 0o755
        assert stat.S_IMODE((root / 'keyrings/owned.gpg').stat().st_mode) == 0o644
    # The management worker must retain its private mask after starting a command.
    assert os.umask(0o077) == 0o077
    SHELL_RC = str(root / 'shell-rc')
    Path(SHELL_RC).write_text('mkdir shell-keyrings\nprintf public > shell-keyrings/key.gpg\nexit\n')
    pwd = types.SimpleNamespace(getpwuid=lambda uid: types.SimpleNamespace(pw_dir=directory))
    start_shell({'size': [24, 80], 'term': 'xterm'})
    assert active['process'].wait() == 0
    os.close(active['master'])
    assert stat.S_IMODE((root / 'shell-keyrings').stat().st_mode) == 0o755
    assert stat.S_IMODE((root / 'shell-keyrings/key.gpg').stat().st_mode) == 0o644
    assert os.umask(0o077) == 0o077
    assert stat.S_IMODE(stage.stat().st_mode) == 0o700
    assert stat.S_IMODE(foreign.stat().st_mode) == 0o600
    assert foreign.read_bytes() == b'foreign'
print('exec and shell permissions, repeated commands, private staging and foreign files passed')
