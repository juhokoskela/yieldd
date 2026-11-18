import hashlib,json,os,platform,re,shutil,subprocess,sys,time
from pathlib import Path
phase=sys.argv[1];env=os.environ
env['PATH']='/Library/Developer/Toolchains/benchmark.xctoolchain/usr/bin:'+env['PATH']
stage=env['BENCH_STAGE'];route=stage.split('-')[0];seed=stage.endswith('seed');cold=stage=='cold';warm=not seed and not cold
root=Path(env['GITHUB_WORKSPACE'])/'GlassEQ'
volume=Path('/Volumes/YielddCache')
store=volume/'swiftpm'
link=root/'.build'
log=Path(env['RUNNER_TEMP'])/'glasseq-evidence';log.mkdir(exist_ok=True)
record=log/'guest.json'
parent='44afeded668e014e7436c9d2a6b6855b7527e5a7';child='497e092cda7b6355de82189a0c45063e99442e08';marker=b'yieldd incremental eq export v1'
def output(*a):return subprocess.check_output(a,cwd=root,text=True).strip()
def command(name,args):
 t=time.perf_counter_ns();start=time.time()
 with (log/(name+'.log')).open('wb') as f:r=subprocess.run(args,cwd=root,stdout=f,stderr=subprocess.STDOUT)
 elapsed=(time.perf_counter_ns()-t)/1e9
 text=(log/(name+'.log')).read_text(errors='replace')
 if r.returncode:
  print(text[-14000:],flush=True);raise RuntimeError(name+' failed: '+str(r.returncode))
 return {'seconds':elapsed,'utc_start':start,'utc_end':time.time(),'compiling_count':sum('Compiling ' in l for l in text.splitlines()),'swift_test_suites':re.findall(r'(?:Executed|with) (\d+) tests?[^\n]{0,110}',text)[-6:]}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save():record.write_text(json.dumps(data,indent=2)+'\n')
def bytesize(p):
 return int(output('du','-sk',str(p)).split()[0])*1024 if p.exists() else 0
def objects():
 out={}
 for f in sorted(store.rglob('*.o')):
  if not f.is_file():continue
  s=f.stat();key=str(f.relative_to(store));v={'mtime_ns':s.st_mtime_ns,'size':s.st_size}
  if any(x in key for x in ('ImportedEQTextDetector','Biquad','EQProfile','GlassEQCore.build/GlassEQCore.swift.o')):v['sha256']=sha(f)
  out[key]=v
 return out
def checkpoint():return str(env['GITHUB_RUN_ID'])+'-parent'
if phase=='prepare':
 assert str(root)=='/Users/runner/actions-runner/_work/yieldd/yieldd/GlassEQ'
 exclude=root/'.git/info/exclude';exclude.parent.mkdir(exist_ok=True);exclude.open('a').write('\n/.build\n')
 rev=output('python3',str(Path(__file__).with_name('fixture.py')),'parent' if seed else 'changed',str(root)).splitlines()[-1];assert rev==(parent if seed else child),rev
 swift=output('swift','--version');xcode=output('xcodebuild','-version')
 assert 'Swift version 6.4.2' in swift and xcode=='Xcode 26.6\nBuild version 17F113'
 data={'stage':stage,'run':env['GITHUB_RUN_ID'],'runner':env['RUNNER_NAME'],'revision':rev,'toolchain':{'swift':swift,'swift_path':shutil.which('swift'),'xcode':xcode,'os':output('sw_vers','-productVersion'),'build':output('sw_vers','-buildVersion'),'arch':platform.machine(),'cpu':output('sysctl','-n','hw.ncpu'),'mem':output('sysctl','-n','hw.memsize'),'developer_dir':env['DEVELOPER_DIR'],'sdk':output('xcrun','--show-sdk-version'),'source':str(root),'cache':str(store)},'times':{}}
 assert data['toolchain']['cpu']=='4' and data['toolchain']['arch']=='arm64'
 assert not link.exists() and not link.is_symlink() and not store.exists()
 if route=='native':assert not volume.exists()
 else:assert (volume/'.yieldd-benchmark-local-dir').read_text()=='guest-root' and volume.stat().st_dev==volume.parent.stat().st_dev
 save()
elif phase=='work':
 data=json.loads(record.read_text());assert not link.exists()
 if route=='native':assert env['YIELDD_CACHE_PATH']==str(volume) and volume.stat().st_dev!=volume.parent.stat().st_dev
 if warm:
  assert (store/'yieldd-benchmark-parent').read_text()==checkpoint()
  assert not (store/'yieldd-benchmark-changed').exists()
  if route in ('remote','local'):assert env['ARCHIVE_HIT']=='true'
 else:
  assert not store.exists()
  store.mkdir()
 link.symlink_to(store,target_is_directory=True)
 assert link.resolve()==store
 data['parent_marker_verified']=warm;data['exact_archive_hit']=warm and route in ('remote','local');data['input_bytes']=bytesize(store)
 before=objects();data['objects_before']=len(before);(log/'before-objects.json').write_text(json.dumps(before))
 for label,cmd in [('debug',['swift','build']),('test',['swift','test']),('release',['./Scripts/build-release-app.sh'])]:
  data['times'][label]=command(label,cmd);save()
 app=link/'release-app/GlassEQ.app';helper=app/'Contents/Helpers/GlassEQSettings.app';binary=helper/'Contents/MacOS/GlassEQSettings'
 data['times']['verify']=command('verify',['codesign','--verify','--deep','--strict',str(app)])
 assert binary.is_file() and (marker in binary.read_bytes())==(not seed)
 data['binary_marker_present']=not seed;data['binary_sha256']=sha(binary)
 for f in [app,helper]:subprocess.run(['codesign','--verify','--strict',str(f)],check=True)
 zips=list((link/'dist').glob('*.zip'));assert len(zips)==1,zips
 data['release_zip_bytes']=zips[0].stat().st_size
 assert not output('git','status','--porcelain','--untracked-files=all')
 for f in (link/'release-app',link/'dist'):shutil.rmtree(f)
 if seed:(store/'yieldd-benchmark-parent').write_text(checkpoint())
 else:(store/'yieldd-benchmark-changed').write_text(env['GITHUB_RUN_ID']+'-'+stage)
 after=objects();(log/'after-objects.json').write_text(json.dumps(after));data['objects_after']=len(after)
 both=before.keys() & after.keys();data['objects_same_size_and_mtime']=sum(before[k]['mtime_ns']==after[k]['mtime_ns'] and before[k]['size']==after[k]['size'] for k in both);data['objects_with_new_mtime']=sum(before[k]['mtime_ns']!=after[k]['mtime_ns'] for k in both)
 data['output_bytes']=bytesize(store);save()
else:raise ValueError(phase)
