"""Tester-home policy and descriptor tests; no real sudo, accounts, or admin files.

Identity database calls are fakes; the default UID and filesystem ownership are the real
unprivileged test process. Shell-flow stubs never elevate. This is not Mac kernel proof.
"""
import contextlib
import fcntl
import io
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'scripts/public/tester.sh'


def sudo_stub():
    return '''#!''' + sys.executable + '''
import builtins,fcntl,io,os,pwd,grp,sys
from types import SimpleNamespace
args=sys.argv[1:]
def trace(text):
 with builtins.open(os.environ["TRACE"],"a") as f:f.write(text+"\\n")
if args[:2]!=["-u","takestester"]:
 trace("root-command "+" ".join(args))
 sys.exit(0 if args and args[0] in ["sysadminctl","createhomedir"] else 99)
if args[2:6]!=["/usr/bin/python3","-I","-c",args[-1]]:sys.exit(98)
trace("-u takestester /usr/bin/python3 -I -c [helper and .zshrc]")
payload=sys.stdin.buffer.read()
trace("stdin source bytes "+str(len(payload)))
home=os.environ["TEST_HOME"]
code=args[-1].replace("/Users/takestester",home)
pwd.getpwnam=lambda name:SimpleNamespace(pw_name="takestester",pw_uid=os.getuid(),pw_gid=os.getgid(),pw_dir=home)
grp.getgrnam=lambda name:SimpleNamespace(gr_gid=80)
os.getgrouplist=lambda name,gid:[gid]
# Model sudo's target supplementary groups, not the Mac admin test runner's groups.
os.getgroups=lambda:[os.getgid()]
original_open=os.open
for name in ["mkdir","replace","unlink","fchmod","link","write"]:
 original=getattr(os,name)
 def wrapped(*a,_name=name,_original=original,**kw):
  trace("write-as-tester "+_name)
  return _original(*a,**kw)
 setattr(os,name,wrapped)
def opened(path,flags,*a,**kw):
 if os.fspath(path)==os.environ.get("ADMIN_SOURCE"):
  raise PermissionError("tester cannot read the admin checkout by path")
 if flags&(os.O_WRONLY|os.O_RDWR|os.O_CREAT|os.O_TRUNC):trace("write-as-tester open")
 if "Shared" in os.fspath(path):raise AssertionError("Shared must not be accessed")
 return original_open(path,flags,*a,**kw)
os.open=opened
original_flock=fcntl.flock
def flocked(fd,operation):
 trace("tester-lock-attempt")
 original_flock(fd,operation)
 trace("tester-lock-acquired")
fcntl.flock=flocked
original_builtin=builtins.open
def source_guard(path,*a,**kw):
 if isinstance(path,(str,bytes,os.PathLike)) and os.fspath(path)==os.environ.get("ADMIN_SOURCE"):
  raise PermissionError("tester cannot read the admin source by path")
 return original_builtin(path,*a,**kw)
builtins.open=source_guard
try:
 builtins.open(os.environ["ADMIN_SOURCE"],"rb")
except PermissionError:
 trace("tester path source read blocked")
else:sys.exit(97)
sys.stdin=io.TextIOWrapper(io.BytesIO(payload))
exec(compile(code,"tester-home-child","exec"),{"__name__":"__main__"})
'''


class Fixture:
    def __init__(self, case):
        tmp = tempfile.TemporaryDirectory(); case.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.home = self.root/'Users/takestester'; self.home.mkdir(parents=True)
        self.home.chmod(0o700)
        self.uid, self.gid = os.getuid(), os.getgid()
        self.helper = self.home/'.local/share/takes-tester'
        self.rc = self.home/'.zshrc'
        self.payload = SOURCE.read_bytes()
        text = self.payload.decode()
        self.code = text.split("<<'INSTALL_TESTER_HOME'\n",1)[1].split('\nINSTALL_TESTER_HOME',1)[0] if "<<'INSTALL_TESTER_HOME'\n" in text else None
        self.ns = {'__name__':'fixture'}
        if self.code: exec(compile(self.code.replace('/Users/takestester',str(self.home)),str(SOURCE),'exec'),self.ns)

    def install(self, payload=None, stream=None, identity=None, groups=None):
        if not self.code: raise unittest.SkipTest('Installer did not exist before the repair')
        entry = dict(pw_name='takestester',pw_uid=self.uid,pw_gid=self.gid,pw_dir=str(self.home))
        entry.update(identity or {})
        previous = os.umask(0o077)
        os.umask(previous)
        try:
            with patch('pwd.getpwnam',return_value=SimpleNamespace(**entry)), \
                 patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=80)), \
                 patch('os.getgrouplist',return_value=[self.gid]), \
                 patch('os.getgroups',return_value=[self.gid] if groups is None else groups):
                self.ns['install'](stream if stream is not None else io.BytesIO(self.payload if payload is None else payload))
        finally:
            # Production runs in a fresh child; direct tests must not leak its process umask.
            os.umask(previous)

    def prepare(self):
        self.rc.write_bytes(b'# user settings\n'); self.rc.chmod(0o640)
        self.install()
        # Make both leaves need updates, without changing ownership/type invariants.
        (self.helper/'tester.sh').write_bytes(b'old helper'); (self.helper/'tester.sh').chmod(0o700)
        self.rc.write_bytes(b'# user settings\n'); self.rc.chmod(0o640)

    def assert_old(self, case):
        case.assertEqual((self.helper/'tester.sh').read_bytes(),b'old helper')
        case.assertEqual(self.rc.read_bytes(),b'# user settings\n')

    def shell(self, missing_account=False, start=False):
        script=self.root/'tester.sh'; script.write_bytes(self.payload)
        tools=self.root/'bin'; tools.mkdir(exist_ok=True)
        for name,body in {'sudo':sudo_stub(),'id':'#!/bin/sh\nexit '+('1' if missing_account else '0')+'\n'}.items():
            p=tools/name;p.write_text(body);p.chmod(0o755)
        env={'HOME':str(self.root/'admin-home'),'USER':'synthetic-admin','PATH':str(tools)+':/usr/bin:/bin',
             'TEST_HOME':str(self.home),'TRACE':str(self.root/'trace'),'ADMIN_SOURCE':str(script)}
        if start:
            return subprocess.Popen(['bash',str(script),'setup'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        return subprocess.run(['bash',str(script),'setup'],env=env,capture_output=True,text=True,timeout=60)


@unittest.skipUnless(SOURCE.is_file(),'The public export omits tester tooling')
@unittest.skipIf(os.getuid()==0,'These fixtures must run unprivileged')
class TesterHome(unittest.TestCase):
    def fixture(self): return Fixture(self)

    def test_full_setup_streams_source_without_privileged_user_path_writes(self):
        f=self.fixture()
        # A hostile old Shared tree must be left entirely alone.
        shared=f.root/'Users/Shared/Takes Tester';shared.mkdir(parents=True)
        victim=f.root/'admin-sentinel';victim.write_bytes(b'keep')
        (shared/'tester.sh').symlink_to(victim)
        p=f.shell(missing_account=True)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        trace=(f.root/'trace').read_text()
        roots=[line for line in trace.splitlines() if line.startswith('root-command')]
        self.assertEqual(len(roots),2)
        self.assertTrue(roots[0].startswith('root-command sysadminctl -addUser takestester'))
        self.assertTrue(roots[1].startswith('root-command createhomedir -c -u takestester'))
        self.assertIn('-u takestester /usr/bin/python3 -I -c',trace)
        self.assertIn('write-as-tester',trace)
        self.assertIn('stdin source bytes '+str(len(f.payload)),trace)
        self.assertIn('tester path source read blocked',trace)
        self.assertEqual((f.helper/'tester.sh').read_bytes(),f.payload)
        self.assertEqual(victim.read_bytes(),b'keep');self.assertTrue((shared/'tester.sh').is_symlink())

    def test_marker_modes_migration_idempotence_and_old_shared_alias(self):
        f=self.fixture(); old=b'alias tester=\'"/Users/Shared/Takes Tester/tester.sh"\'\n'
        f.rc.write_bytes(b'# custom\n'+old);f.rc.chmod(0o640)
        f.install()
        expected=b'# custom\n'+old
        profile=f.rc.read_bytes();self.assertTrue(profile.startswith(expected))
        self.assertEqual((f.helper/'.takes-tester-helper').read_bytes(),b'takes-tester-helper-v1\n')
        for path,mode in [(f.helper,0o700),(f.helper/'.takes-tester-helper',0o600),(f.helper/'tester.sh',0o700),(f.rc,0o640)]:
            self.assertEqual(path.stat().st_uid,os.getuid());self.assertEqual(path.stat().st_mode&0o7777,mode)
        before=[p.stat().st_ino for p in [f.rc,f.helper/'tester.sh']]
        f.install()
        self.assertEqual(f.rc.read_bytes(),profile)
        self.assertEqual([p.stat().st_ino for p in [f.rc,f.helper/'tester.sh']],before)
        f.rc.write_bytes(profile+b'\n  \n')
        trailing=f.rc.read_bytes();inode=f.rc.stat().st_ino
        f.install()
        self.assertEqual(f.rc.read_bytes(),trailing);self.assertEqual(f.rc.stat().st_ino,inode)
        p=subprocess.run(['bash','--noprofile','--norc','-c','source "$1"; alias tester','fixture',str(f.rc)],capture_output=True,text=True,check=True)
        self.assertIn(str(f.helper/'tester.sh'),p.stdout)
        self.assertNotIn('/Users/Shared',p.stdout)

    def test_helper_survives_a_stubbed_reset(self):
        f=self.fixture();f.install();tools=f.root/'reset-bin';tools.mkdir()
        for name in ['pgrep','pkill','defaults','killall','tccutil','security','claude']:
            p=tools/name;p.write_text('#!/bin/sh\nexit '+('1' if name=='pgrep' else '0')+'\n');p.chmod(0o755)
        p=subprocess.run(['bash',str(f.helper/'tester.sh'),'reset','--keep-claude'],capture_output=True,text=True,timeout=60,
            env={'HOME':str(f.home),'USER':'takestester','PATH':str(tools)+':/usr/bin:/bin'})
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertEqual((f.helper/'tester.sh').read_bytes(),f.payload)
        self.assertTrue(f.rc.is_file())

    def test_source_checks_and_read_failure_precede_all_writes(self):
        for payload in [b'',b'#!/bin/bash\n# A second macOS user ',b'not a tester helper',b'x'*(1024*1024+1)]:
            with self.subTest(size=len(payload)):
                f=self.fixture()
                with patch('os.mkdir') as mkdir,patch('os.replace') as replace:
                    with self.assertRaises(RuntimeError): f.install(payload)
                    mkdir.assert_not_called();replace.assert_not_called()
                self.assertFalse(f.rc.exists())
        f=self.fixture()
        class Broken:
            def read(self,*a):raise OSError('synthetic source read failure')
        with patch('os.mkdir') as mkdir:
            with self.assertRaises(OSError):f.install(stream=Broken())
            mkdir.assert_not_called()

    def test_uid_home_name_and_admin_checks_precede_writes(self):
        for identity in [{'pw_uid':0},{'pw_uid':os.getuid()+1},{'pw_dir':'/unexpected'},{'pw_name':'someone-else'}]:
            with self.subTest(identity=identity):
                f=self.fixture()
                with patch('os.mkdir') as mkdir:
                    with self.assertRaises(RuntimeError):f.install(identity=identity)
                    mkdir.assert_not_called()
        for call,value in [('os.getuid',0),('os.geteuid',0),('os.getgroups',[80]),('os.getgid',80),('os.getegid',80)]:
            with self.subTest(call=call):
                f=self.fixture()
                with patch(call,return_value=value),patch('os.mkdir') as mkdir:
                    with self.assertRaises(RuntimeError):f.install(groups=value if call=='os.getgroups' else None)
                    mkdir.assert_not_called()
        f=self.fixture()
        # Membership reported by the account database, even when absent from inherited groups.
        with patch('os.getgrouplist',return_value=[80]),patch('pwd.getpwnam',return_value=SimpleNamespace(pw_name='takestester',pw_uid=f.uid,pw_gid=f.gid,pw_dir=str(f.home))),patch('grp.getgrnam',return_value=SimpleNamespace(gr_gid=80)),patch('os.mkdir') as mkdir:
            with self.assertRaises(RuntimeError):f.ns['install'](io.BytesIO(f.payload))
            mkdir.assert_not_called()

    def test_unsafe_directories_and_symlinks_are_not_adopted(self):
        for component in ['home','.local','.local/share','.local/share/takes-tester']:
            with self.subTest(component=component):
                f=self.fixture();outside=f.root/'outside';outside.mkdir();(outside/'keep').write_text('keep')
                path=f.home if component=='home' else f.home/component
                path.parent.mkdir(parents=True,exist_ok=True)
                for parent in [f.home/'.local',f.home/'.local/share']:
                    if parent.is_dir():parent.chmod(0o700)
                if path==f.home:path.rmdir()
                path.symlink_to(outside,target_is_directory=True)
                with self.assertRaises(OSError):f.install()
                self.assertTrue(path.is_symlink());self.assertEqual(list(outside.iterdir()),[outside/'keep'])
        for mode in [0o755,0o770,0o777]:
            with self.subTest(helper_mode=mode):
                f=self.fixture();f.helper.mkdir(parents=True);f.helper.chmod(mode)
                for parent in [f.home/'.local',f.home/'.local/share']:parent.chmod(0o700)
                (f.helper/'keep').write_text('keep')
                with self.assertRaises(RuntimeError):f.install()
                self.assertEqual((f.helper/'keep').read_text(),'keep');self.assertEqual(f.helper.stat().st_mode&0o7777,mode)

    def test_foreign_directory_owner_and_writable_parent_are_refused(self):
        for component in ['home','.local','.local/share','.local/share/takes-tester']:
            with self.subTest(component=component):
                f=self.fixture();f.prepare();path=f.home if component=='home' else f.home/component
                inode=path.stat().st_ino;real=os.fstat
                def foreign(fd):
                    info=real(fd)
                    return SimpleNamespace(st_uid=f.uid+1,st_mode=info.st_mode) if info.st_ino==inode else info
                with patch('os.fstat',side_effect=foreign):
                    with self.assertRaises(RuntimeError):f.install()
                f.assert_old(self)
        f=self.fixture();f.prepare();(f.home/'.local').chmod(0o770)
        with self.assertRaises(RuntimeError):f.install()
        f.assert_old(self)

    def test_marker_is_exact_private_single_link_owned_and_real(self):
        for kind in ['missing','contents','mode','symlink','dangling','directory','fifo','hardlink','foreign','extra']:
            with self.subTest(kind=kind):
                f=self.fixture();f.prepare();marker=f.helper/'.takes-tester-helper'
                if kind=='missing':marker.unlink()
                elif kind=='contents':marker.write_bytes(b'wrong version\n')
                elif kind=='mode':marker.chmod(0o644)
                elif kind in ['symlink','dangling','directory','fifo']:
                    marker.unlink()
                    if kind in ['symlink','dangling']:marker.symlink_to(f.rc if kind=='symlink' else f.root/'missing')
                    elif kind=='directory':marker.mkdir()
                    else:os.mkfifo(marker)
                elif kind=='hardlink':os.link(marker,f.root/'another-link')
                elif kind=='extra':(f.helper/'unrelated').write_text('keep')
                inode=marker.lstat().st_ino if marker.exists() or marker.is_symlink() else None
                real=os.fstat
                def foreign(fd):
                    s=real(fd)
                    return SimpleNamespace(**{name:getattr(s,name) for name in ['st_mode','st_nlink','st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns']},st_uid=f.uid+1) if s.st_ino==inode else s
                with (patch('os.fstat',side_effect=foreign) if kind=='foreign' else contextlib.nullcontext()):
                    with self.assertRaises((OSError,RuntimeError)):f.install()
                f.assert_old(self)

    def test_helper_and_profile_leaf_types_hardlinks_and_owners_preserve_data(self):
        for leaf in ['helper','profile']:
            for kind in ['symlink','dangling','directory','fifo','socket','hardlink','foreign','writeable']:
                with self.subTest(leaf=leaf,kind=kind):
                    f=self.fixture();f.prepare();dest=f.rc if leaf=='profile' else f.helper/'tester.sh'
                    outside=f.root/'protected';outside.write_bytes(b'keep')
                    if kind in ['symlink','dangling','directory','fifo','socket']:
                        dest.unlink()
                        if kind in ['symlink','dangling']:dest.symlink_to(outside if kind=='symlink' else f.root/'missing')
                        elif kind=='directory':dest.mkdir()
                        elif kind=='fifo':os.mkfifo(dest)
                        else:
                            # Darwin's Unix socket path limit is short; bind before moving it
                            # into the deeper helper fixture. Only its leaf type is tested.
                            short=f.root/'s'
                            sock=socket.socket(socket.AF_UNIX);sock.bind(str(short));sock.close();short.rename(dest)
                    elif kind=='hardlink':os.link(dest,f.root/'another-link')
                    elif kind=='writeable':dest.chmod(0o777)
                    before=dest.lstat();real=os.fstat
                    def foreign(fd):
                        s=real(fd)
                        return SimpleNamespace(st_uid=f.uid+1,st_mode=s.st_mode,st_nlink=s.st_nlink) if s.st_ino==before.st_ino else s
                    with (patch('os.fstat',side_effect=foreign) if kind=='foreign' else contextlib.nullcontext()):
                        with self.assertRaises((OSError,RuntimeError)):f.install()
                    after=dest.lstat();self.assertEqual((before.st_ino,before.st_mode),(after.st_ino,after.st_mode))
                    self.assertEqual(outside.read_bytes(),b'keep')

    def test_staging_and_prepublication_failure_preserves_both_leaves(self):
        for method in ['write','mode','sync-helper','replace-helper']:
            with self.subTest(method=method):
                f=self.fixture();f.prepare();real_sync=os.fsync;real_replace=os.replace;calls=0
                def sync(fd):
                    nonlocal calls
                    calls+=1
                    if calls==1:raise OSError('synthetic sync failure')
                    return real_sync(fd)
                def replace(src,dst,**kw):
                    if dst=='tester.sh':raise OSError('synthetic publish failure')
                    return real_replace(src,dst,**kw)
                real_fdopen=os.fdopen
                def broken_write(fd,mode):
                    file=real_fdopen(fd,mode)
                    if mode!='wb':return file
                    class Output:
                        def __enter__(self):return self
                        def __exit__(self,*a):file.close()
                        def write(self,data):
                            file.write(data[:7]);file.flush();raise OSError('synthetic partial copy failure')
                    return Output()
                target='os.fdopen' if method=='write' else 'os.fchmod' if method=='mode' else 'os.replace' if method=='replace-helper' else 'os.fsync'
                effect=broken_write if method=='write' else OSError('mode failure') if method=='mode' else replace if method=='replace-helper' else sync
                with patch(target,side_effect=effect):
                    with self.assertRaises(OSError):f.install()
                f.assert_old(self)
                self.assertFalse(list(f.home.glob('.takes-tmp-*')));self.assertFalse(list(f.helper.glob('.takes-tmp-*')))

    def test_alias_write_failure_does_not_claim_to_roll_back_helper(self):
        for failure in ['write','short-write','sync']:
            with self.subTest(failure=failure):
                f=self.fixture();f.prepare();real_write=os.write;real_sync=os.fsync
                def written(fd,data):
                    if failure=='write':raise OSError('alias write failure')
                    return real_write(fd,data[:4] if failure=='short-write' else data)
                def synced(fd):
                    if failure=='sync' and os.fstat(fd).st_ino==f.rc.stat().st_ino:
                        raise OSError('alias sync failure')
                    return real_sync(fd)
                with patch('os.write',side_effect=written),patch('os.fsync',side_effect=synced):
                    with self.assertRaises(OSError):f.install()
                self.assertTrue(f.rc.read_bytes().startswith(b'# user settings\n'))
                if failure=='write':self.assertEqual(f.rc.read_bytes(),b'# user settings\n')
                self.assertEqual(f.rc.stat().st_mode&0o7777,0o640)
                self.assertEqual((f.helper/'tester.sh').read_bytes(),f.payload)
                self.assertFalse(list(f.home.glob('.takes-tmp-*')))

    def test_directory_replacement_before_open_after_open_and_at_publish(self):
        for moment in ['before-open','after-open','publish']:
            with self.subTest(moment=moment):
                f=self.fixture();f.prepare();outside=f.root/'outside';outside.mkdir();(outside/'tester.sh').write_bytes(b'keep')
                real_open=os.open;real_replace=os.replace;fired=False
                def swap():
                    nonlocal fired
                    fired=True;f.helper.rename(f.helper.with_name('old'));f.helper.symlink_to(outside,target_is_directory=True)
                def opened(path,flags,*a,**kw):
                    if path=='takes-tester' and moment=='before-open' and not fired:swap()
                    fd=real_open(path,flags,*a,**kw)
                    if path=='takes-tester' and moment=='after-open' and not fired:swap()
                    return fd
                def replaced(src,dst,**kw):
                    if dst=='tester.sh' and not fired:swap()
                    return real_replace(src,dst,**kw)
                with patch('os.open',side_effect=opened),patch('os.replace',side_effect=replaced):
                    with self.assertRaises((OSError,RuntimeError)):f.install()
                self.assertEqual((outside/'tester.sh').read_bytes(),b'keep')
                self.assertEqual(f.rc.read_bytes(),b'# user settings\n')
                self.assertFalse(list(f.helper.with_name('old').glob('.takes-tmp-*')))

    def test_late_legitimate_profile_append_survives_publication(self):
        # The replace hook reproduces 2f993228 exactly; the write hook exercises its repair.
        for addition in [b'# legitimate concurrent editor setting\n',b'# legitimate no-newline append']:
            with self.subTest(addition=addition):
                f=self.fixture();f.prepare();before=f.rc.stat();injected=False;writes=[]
                real_replace=os.replace;real_write=os.write
                def edit():
                    nonlocal injected
                    self.assertFalse(injected);injected=True
                    with f.rc.open('ab') as file:file.write(addition)
                def replaced(src,dst,**kw):
                    if dst=='.zshrc':edit()
                    return real_replace(src,dst,**kw)
                def written(fd,data):
                    self.assertEqual(os.fstat(fd).st_ino,before.st_ino)
                    self.assertTrue(fcntl.fcntl(fd,fcntl.F_GETFL)&os.O_APPEND)
                    self.assertTrue(data.startswith(b'\n'));self.assertLess(len(data),1024)
                    edit();writes.append(data)
                    return real_write(fd,data)
                with patch('os.replace',side_effect=replaced),patch('os.write',side_effect=written):f.install()
                self.assertTrue(injected)
                self.assertIn(addition,f.rc.read_bytes())
                self.assertEqual(len(writes),1)
                self.assertEqual(f.rc.read_bytes(),b'# user settings\n'+addition+writes[0])
                self.assertEqual((f.rc.stat().st_ino,f.rc.stat().st_mode),(before.st_ino,before.st_mode))

    def test_replaced_profile_window_reports_failure_and_preserves_new_file(self):
        for moment in ['before-write','after-write']:
            with self.subTest(moment=moment):
                f=self.fixture();f.prepare();real_write=os.write;real_replace=os.replace;injected=False
                def edit():
                    nonlocal injected
                    injected=True;f.rc.rename(f.root/'old-profile')
                    f.rc.write_bytes(b'# newly saved editor profile\n');f.rc.chmod(0o600)
                def written(fd,data):
                    if moment=='before-write':edit()
                    n=real_write(fd,data)
                    if moment=='after-write':edit()
                    return n
                def replaced(src,dst,**kw):
                    if dst=='.zshrc':edit()
                    return real_replace(src,dst,**kw)
                with patch('os.write',side_effect=written),patch('os.replace',side_effect=replaced):
                    with self.assertRaises(RuntimeError):f.install()
                self.assertTrue(injected)
                self.assertEqual(f.rc.read_bytes(),b'# newly saved editor profile\n')
                self.assertEqual(f.rc.stat().st_mode&0o7777,0o600)
                self.assertTrue((f.root/'old-profile').read_bytes().startswith(b'# user settings\n'))

    def test_fresh_profile_is_exclusive_and_does_not_adopt_window_creation(self):
        f=self.fixture();real=os.open;injected=False
        def opened(path,flags,*a,**kw):
            nonlocal injected
            if path=='.zshrc' and flags&os.O_CREAT:
                self.assertTrue(flags&os.O_EXCL);self.assertTrue(flags&os.O_NOFOLLOW)
                injected=True;f.rc.write_bytes(b'# concurrently created profile\n');f.rc.chmod(0o640)
            return real(path,flags,*a,**kw)
        with patch('os.open',side_effect=opened):
            with self.assertRaises(FileExistsError):f.install()
        self.assertTrue(injected)
        self.assertEqual(f.rc.read_bytes(),b'# concurrently created profile\n')
        self.assertEqual(f.rc.stat().st_mode&0o7777,0o640)

    def test_cooperating_setup_waits_for_marker_lock_and_is_idempotent(self):
        f=self.fixture();f.prepare()
        with (f.helper/'.takes-tester-helper').open('r+b') as held:
            fcntl.flock(held,fcntl.LOCK_EX)
            child=f.shell(start=True)
            try:
                deadline=time.monotonic()+60
                while not (f.root/'trace').exists() or 'tester-lock-attempt' not in (f.root/'trace').read_text():
                    self.assertIsNone(child.poll(),'setup exited before taking marker lock')
                    self.assertLess(time.monotonic(),deadline,'setup never attempted marker lock')
                    time.sleep(0.01)
                self.assertIsNone(child.poll());f.assert_old(self)
                self.assertNotIn('tester-lock-acquired',(f.root/'trace').read_text())
            finally:
                fcntl.flock(held,fcntl.LOCK_UN)
                out,err=child.communicate(timeout=60)
        self.assertEqual(child.returncode,0,out+err)
        before=f.rc.read_bytes();inode=f.rc.stat().st_ino
        self.assertEqual(before.count(b'alias tester='),1)
        result=f.shell();self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(f.rc.read_bytes(),before);self.assertEqual(f.rc.stat().st_ino,inode)

    def test_replaced_helper_temp_is_not_published_or_cleaned(self):
        f=self.fixture();f.prepare();real=os.fsync;foreign=None
        def sync(fd):
            nonlocal foreign
            real(fd)
            temp=next(f.helper.glob('.takes-tmp-*'));temp.unlink();temp.write_bytes(b'foreign temporary');foreign=temp
        with patch('os.fsync',side_effect=sync):
            with self.assertRaises(RuntimeError):f.install()
        f.assert_old(self);self.assertIsNotNone(foreign)
        self.assertEqual(foreign.read_bytes(),b'foreign temporary')


if __name__=='__main__':unittest.main()
