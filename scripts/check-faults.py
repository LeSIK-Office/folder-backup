#!/usr/bin/env python3
"""Run destructive fault injection only inside a newly created test disk image."""
import atexit,datetime,hashlib,json,os,pathlib,plistlib,signal,sqlite3,subprocess,time,uuid
base=pathlib.Path(__file__).resolve().parent.parent
worker=base/'.build/fault-recovery-check'
if not worker.is_file():raise SystemExit('Build the test worker with scripts/check-release.sh first.')
work=base/'.build'/('FaultRecovery-'+str(uuid.uuid4()));work.mkdir()
image=work/'Fault APFS.sparsebundle';mount=pathlib.Path('/Volumes')/('FolderBackupFault-'+uuid.uuid4().hex[:8])
subprocess.run(['hdiutil','create','-size','1g','-fs','APFS','-type','SPARSEBUNDLE','-volname',mount.name,'-o',str(image)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
owned_processes=[]
def cleanup():
 for process in owned_processes:
  if process.poll() is None:process.kill();process.wait()
 subprocess.run(['hdiutil','detach',str(mount)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=20)
atexit.register(cleanup)
source=work/'Source';source.mkdir();restores=work/'Restores';restores.mkdir()
destination=mount/'Backup';destination.mkdir();fulltarget=mount/'RestoreTests';fulltarget.mkdir();plan=str(uuid.uuid4()).upper();root=destination/'Toolkit Backups'/plan;root.mkdir(parents=True)
report={'startedAt':datetime.datetime.now().astimezone().isoformat(),'fixture':str(work),'testImage':str(image),'planID':plan,'cases':[]}

def record(case,**detail):
 report['cases'].append(dict(case=case,**detail));print('CASE',case,json.dumps(detail,ensure_ascii=False),flush=True)
 (work/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')

def write_files(prefix,count):
 for i in range(count):
  payload=hashlib.sha256((prefix+str(i)).encode()).digest()*128
  (source/(prefix+f'{i:04}.txt')).write_bytes(payload)

def config(mode,label,hold=0,parent=restores):
 p=work/(label+'.json');result=work/(label+'-result.json');marker=work/(label+'-paused');release=work/(label+'-release')
 cfg=dict(mode=mode,source=source.as_uri(),destination=destination.as_uri(),planID=plan,result=result.as_uri(),restoreParent=parent.as_uri(),holdAfter=hold,marker=marker.as_uri(),release=release.as_uri())
 p.write_text(json.dumps(cfg));return p,result,marker,release

def run(mode,label,expect='pass',parent=restores):
 cfg,result,_,_=config(mode,label,parent=parent)
 p=subprocess.run([str(base/'.build/fault-recovery-check'),str(cfg)],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120)
 (work/(label+'.log')).write_text(p.stdout)
 data=json.loads(result.read_text());assert data['status']==expect,(label,data)
 return data

def pause(label):
 cfg,result,marker,release=config('backup',label,300)
 log=(work/(label+'.log')).open('w');p=subprocess.Popen([str(worker),str(cfg)],stdout=log,stderr=subprocess.STDOUT);owned_processes.append(p)
 deadline=time.monotonic()+120
 while not marker.exists():
  assert p.poll() is None,(label,'worker exited before pause')
  assert time.monotonic()<deadline,'pause timed out';time.sleep(.02)
 return p,result,release,log

def snapshots():return sorted(p.name for p in root.glob('20*'))

write_files('file-',600)
for i in range(16):(source/f'large-{i:02}.bin').write_bytes(hashlib.sha256(str(i).encode()).digest()*(2*1024*1024//32))
(source/'빈 폴더').mkdir();(source/'日本語 한국어.txt').write_text('Unicode metadata recovery');os.chmod(source/'日本語 한국어.txt',0o640);subprocess.run(['xattr','-w','com.folderbackup.test','metadata recovery',str(source/'日本語 한국어.txt')],check=True);os.symlink('file-0000.txt',source/'link')
with sqlite3.connect(root/'.objects.sqlite') as db:db.executescript('PRAGMA auto_vacuum=INCREMENTAL; CREATE TABLE objects(hash TEXT PRIMARY KEY,data BLOB NOT NULL) WITHOUT ROWID;')
baseline=run('backup','baseline');first=baseline['snapshot']['id'];record('baseline',snapshot=first)
write_files('000-kill-',320)
p,result,release,log=pause('kill');os.kill(p.pid,signal.SIGKILL);p.wait(timeout=10);log.close()
assert snapshots()==[first] and (root/'.partial-current/checkpoint.jsonl').exists()
resumed=run('backup','kill-resume');assert resumed['snapshot']['resumedFiles']>=256 and len(snapshots())==2
run('verify','verify-after-kill');record('SIGKILL backup and resume',passed=True,resumedFiles=resumed['snapshot']['resumedFiles'],oldCompletedPreserved=first in snapshots())
write_files('000-detach-',320)
p,result,release,log=pause('disconnect')
info=plistlib.loads(subprocess.check_output(['hdiutil','info','-plist']))
assert any(pathlib.Path(x.get('image-path','')).resolve()==image.resolve() and any(e.get('mount-point')==str(mount) for e in x.get('system-entities',[])) for x in info['images']), 'Refuse to detach anything except our disposable image'
subprocess.run(['hdiutil','detach','-force',str(mount)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
release.write_text('continue after disconnect');p.wait(timeout=60);log.close();failed=json.loads(result.read_text());assert failed['status']=='error',failed
subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
assert len(snapshots())==2
resumed=run('backup','disconnect-resume');assert len(snapshots())==3;run('verify','verify-after-disconnect');record('Test-image disconnect and remount',passed=True,error=failed['error'],resumedFiles=resumed['snapshot']['resumedFiles'],completedPreserved=True)
previous_restore=run('restore','restore-before-space')['output']
free=os.statvfs(mount);fill_bytes=free.f_bavail*free.f_frsize-96*1024*1024;assert 0<fill_bytes<2*1024*1024*1024
filler=mount/('fault-space-filler-'+str(uuid.uuid4())+'.bin')
with filler.open('wb') as f:
 chunk=bytes(1024*1024)
 while fill_bytes>0:
  n=min(len(chunk),fill_bytes)
  try:f.write(chunk[:n]);fill_bytes-=n
  except OSError as error:
   if error.errno!=28:raise
   break
 f.flush();os.fsync(f.fileno())
with filler.open('r+b') as f:f.truncate(max(0,filler.stat().st_size-16*1024*1024))
(source/'zzz-overflow.bin').write_bytes(hashlib.sha256(b'overflow').digest()*(128*1024*1024//32))
failed=run('backup','full-backup',expect='error');assert len(snapshots())==3
assert (failed['domain'],failed['code']) in [('NSPOSIXErrorDomain',28),('NSCocoaErrorDomain',640)], 'Storage full was hidden in a per-file failure list'
failed_restore=run('restore','full-restore',expect='error',parent=fulltarget)
assert pathlib.Path(previous_restore).exists()
with filler.open('r+b') as f:f.truncate(0)
subprocess.run(['hdiutil','detach',str(mount)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
resumed=run('backup','space-resume');assert len(snapshots())==4;run('verify','verify-after-space')
record('Storage full backup/restore and recovery',passed=True,backupError=failed['error'],restoreError=failed_restore['error'],resumedFiles=resumed['snapshot']['resumedFiles'],completedPreserved=True)
latest=run('restore','latest-restore')['output']
for path in source.rglob('*'):
 relative=path.relative_to(source);target=pathlib.Path(latest)/'Source'/relative
 if path.is_symlink():assert target.is_symlink() and os.readlink(target)==os.readlink(path)
 elif path.is_file():assert hashlib.sha256(path.read_bytes()).digest()==hashlib.sha256(target.read_bytes()).digest()
 else:assert target.is_dir()
assert subprocess.check_output(['xattr','-p','com.folderbackup.test',str(pathlib.Path(latest)/'Source/日本語 한국어.txt')]).strip()==b'metadata recovery'
record('All fixture files restored',passed=True,unicode=True,symlink=True,extendedAttribute=True,permissions=(pathlib.Path(latest)/'Source/日本語 한국어.txt').stat().st_mode&0o777)
# Corrupt one test-only packed object, require detection, then restore its bytes.
with sqlite3.connect(root/'.objects.sqlite') as db:
 key,data=db.execute('SELECT hash,data FROM objects ORDER BY hash LIMIT 1').fetchone();db.execute('UPDATE objects SET data=? WHERE hash=?',(b'corrupted fixture',key))
failed=run('verify','corrupt-verify',expect='error');failed_restore=run('restore','corrupt-restore',expect='error')
with sqlite3.connect(root/'.objects.sqlite') as db:db.execute('UPDATE objects SET data=? WHERE hash=?',(data,key));assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
run('verify','verify-after-repair');record('Packed corruption rejected before restore',passed=True,verifyError=failed['error'],restoreError=failed_restore['error'])
# Kill a restore after it has actually written files; a fresh attempt must succeed.
cfg,result,_,_=config('restore','restore-kill');log=(work/'restore-kill.log').open('w');p=subprocess.Popen([str(worker),str(cfg)],stdout=log,stderr=subprocess.STDOUT);owned_processes.append(p)
deadline=time.monotonic()+120;killed=False;partial=None
while p.poll() is None:
 for candidate in restores.glob('.partial-restore-*'):
  if sum(len(files) for _,_,files in os.walk(candidate))>=10:partial=str(candidate);os.kill(p.pid,signal.SIGKILL);killed=True;break
 if killed:break
 assert time.monotonic()<deadline,'restore-kill timed out';time.sleep(.005)
p.wait(timeout=10);log.close();assert killed,'Restore finished before interruption could be injected'
assert pathlib.Path(latest).exists() and len(snapshots())==4
again=run('restore','restore-after-kill')['output'];assert (pathlib.Path(again)/'Source/zzz-overflow.bin').read_bytes()==(source/'zzz-overflow.bin').read_bytes()
run('verify','final-verify');record('SIGKILL restore and restart',passed=True,interruptedPartialRetained=partial,newRestore=again,previousCompletedRestorePreserved=True,backupVersionsPreserved=4)
report['completedAt']=datetime.datetime.now().astimezone().isoformat();report['passed']=all(c.get('passed',True) for c in report['cases']);report['limitations']=['Disconnect simulated by force-ejecting an owned disk image, not physical cable removal.','Fixtures remain in the reported test folders; no real backup was modified.']
(work/'report.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n');print('FAULT RECOVERY FINAL PASS; retained artifacts: '+str(work),flush=True)
