"""Single-job experiment. Only the upstream action processes receive Actions runtime credentials."""
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
from contextlib import contextmanager
from pathlib import Path

env = os.environ
root = Path(env['RUNNER_TEMP']) / 'cache-proof'
workspace = Path(env['GITHUB_WORKSPACE'])
mount = root / 'working-volume'
root.mkdir(exist_ok=True)
mount.mkdir(exist_ok=True)
original = env['ACTIONS_RESULTS_URL']
local = 'http://127.0.0.1:18371/'
nonce = env['GITHUB_RUN_ID'] + '-' + env['GITHUB_RUN_ATTEMPT']
measurements = []
failures = {}
base_env = {k: v for k, v in env.items() if not k.startswith(('ACTIONS_', 'INPUT_', 'STATE_'))}
base_env.update(GOCACHE=str(mount / 'build'), GOMODCACHE=str(mount / 'modules'), GOWORK='off')
marker = mount / 'build' / 'yieldd-cache-proof'
expected = hashlib.sha256(nonce.encode()).hexdigest()

def timed(label, operation):
    start = time.monotonic()
    value = operation()
    seconds = round(time.monotonic() - start, 3)
    print(f'{label}: {seconds}s', flush=True)
    measurements.append([label, seconds])
    return value

def cmd(*args, cwd=workspace):
    subprocess.run(args, env=base_env, cwd=cwd, check=True)

def outputs(p):
    lines = iter(p.read_text().splitlines())
    values = {}
    for line in lines:
        if '<<' in line:
            name, delim = line.split('<<', 1)
            v = []
            for item in lines:
                if item == delim:
                    break
                v.append(item)
            values[name] = '\n'.join(v)
        elif '=' in line:
            k, v = line.split('=', 1)
            values[k] = v
    return values

def action(script, route, inputs, state=None):
    # Exercise the unmodified pinned dist with the same Node as the enclosing JS action.
    # Only the benchmark launcher substitutes the results origin.
    with tempfile.TemporaryDirectory(dir=root) as tmp:
        e = {**env, **base_env, 'ACTIONS_RESULTS_URL': route}
        for k in ('OUTPUT', 'STATE', 'PATH', 'ENV', 'STEP_SUMMARY'):
            p = Path(tmp) / k
            p.touch()
            e['GITHUB_' + k] = str(p)
        e.update({'INPUT_' + k.upper(): v for k, v in inputs.items()})
        e.update({'STATE_' + k: v for k, v in (state or {}).items()})
        r = subprocess.run([sys.argv[1], str(root / script)], env=e, cwd=workspace,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # Toolkit messages can contain signed blob URLs. Keep only sanitized error context.
        for line in r.stdout.splitlines():
            if any(word in line.lower() for word in ('warning', 'error', 'failed', 'unable')):
                safe = re.sub(r'https?://\S+|[\w.-]{45,}', '[redacted]', line)
                print(safe[:400], flush=True)
        if r.returncode:
            raise RuntimeError(f'{script} exited {r.returncode}')
        return outputs(Path(tmp) / 'OUTPUT'), outputs(Path(tmp) / 'STATE')

def blank(name):
    img = root / (name + '.sparseimage')
    cmd('hdiutil','create','-quiet','-size','4g','-fs','APFS','-volname','yielddbench','-type','SPARSE',str(img))
    return img

@contextmanager
def attached(image, mode):
    timed(mode+' attach',lambda: cmd('hdiutil','attach','-quiet','-nobrowse','-owners','off','-mountpoint',str(mount),str(image)))
    try:
        yield
    finally:
        for attempt in range(4):
            try:
                timed(mode+' detach',lambda: cmd('hdiutil','detach','-quiet',str(mount)))
                break
            except subprocess.CalledProcessError:
                if attempt == 3: raise
                time.sleep(1)

def workload(mode):
    timed(mode+' test',lambda: cmd('go','test','-race','-count=1','./...',cwd=workspace/'Server'))
    timed(mode+' vet',lambda: cmd('go','vet','./...',cwd=workspace/'Server'))

inputs={'go-version-file':'Server/go.mod','cache':'true','check-latest':'false',
        'cache-dependency-path':'.cache-benchmark-key'}
# Add a run nonce to the key only. All modes build the same unmodified server sources.
(workspace/'.cache-benchmark-key').write_bytes((workspace/'Server/go.sum').read_bytes()+nonce.encode())

def go_setup(route):
    return action('setup-go/dist/setup/index.js',route,inputs)

def collect_errors(label, operation):
    try:
        operation()
    except Exception as e:
        failures[label]=str(e)
        print(f'{label}: {type(e).__name__}: {e}',flush=True)

def archive_save(mode, route):
    out,state = go_setup(route)
    if out.get('cache-hit') == 'true':
        raise RuntimeError('seed key already existed')
    timed(mode+' save',lambda: action('setup-go/dist/cache-save/index.js',route,inputs,state))

def archive_trial(mode,route):
    with attached(blank(mode),mode):
        if marker.exists(): raise RuntimeError('expected empty destination')
        out,_=timed(mode+' restore',lambda: go_setup(route))
        if out.get('cache-hit')!='true' or marker.read_text()!=expected:
            raise RuntimeError('missing exact cache hit or restored seed marker')
        workload(mode)

def artifact():
    result = root/'evidence.json'
    result.write_text(json.dumps({'nonce':nonce,'timings':measurements,'failures':failures},indent=2))
    out,_=action('upload/dist/upload/index.js',local,{'name':'routing-proof','path':str(result),'retention-days':'2',
        'if-no-files-found':'error','compression-level':'6','overwrite':'false','include-hidden-files':'false'})
    if not out.get('artifact-id'): raise RuntimeError('artifact ID missing')
    print('ROUTED_ARTIFACT',out['artifact-id'],'FILE_SHA256',hashlib.sha256(result.read_bytes()).hexdigest(),flush=True)

def cache_action():
    # A separate exact-key round trip verifies actions/cache itself in addition to setup-go.
    path=root/'sentinel'
    path.write_text(expected)
    args={'path':str(path),'key':'yieldd-route-'+nonce,'enableCrossOsArchive':'false',
          'lookup-only':'false','fail-on-cache-miss':'true'}
    action('cache/dist/save-only/index.js',local,args)
    path.unlink()
    out,_=action('cache/dist/restore-only/index.js',local,args)
    if out.get('cache-hit')!='true' or path.read_text()!=expected: raise RuntimeError('sentinel missing')

def main():
    server_env={**base_env,'API_BASE_URL':local.rstrip('/'),'PORT':'18371','HOST':'127.0.0.1',
                'DEFAULT_ACTIONS_RESULTS_URL':original.rstrip('/')}
    data=root/'data'
    data.mkdir()
    server=subprocess.Popen([root/'server/target/debug/github-actions-cache-server'],env=server_env,cwd=data,
                            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        for _ in range(80):
            if server.poll() is not None: raise RuntimeError('cache server exited during startup')
            try:
                with urllib.request.urlopen(local+'health',timeout=1) as r:
                    if r.status==200: break
            except OSError: time.sleep(.25)
        else: raise RuntimeError('cache server did not start')
        collect_errors('actions/cache round trip',cache_action)
        seed=blank('seed')
        with attached(seed,'cold'):
            workload('cold')
            marker.write_text(expected)
            for mode,route in [('remote',original),('local',local)]:
                collect_errors(mode+' seed',lambda: archive_save(mode,route))
        for mode,route in [('remote',original),('local',local)]:
            collect_errors(mode+' warm',lambda: archive_trial(mode,route))
        clone=root/'native.sparseimage'
        timed('native clone',lambda: cmd('cp','-c',str(seed),str(clone)))
        with attached(clone,'native'):
            if marker.read_text()!=expected: raise RuntimeError('native seed missing')
            workload('native')
        with urllib.request.urlopen(local+'metrics') as response:
            for line in response.read().decode().splitlines():
                if line.startswith(('cache_uploads_total','cache_requests_total','cache_storage_bytes')):
                    print(line,flush=True)
        collect_errors('artifact forwarding',artifact)
    finally:
        server.terminate()
        server.wait(timeout=10)
    print('RESULT',json.dumps({'timings':measurements,'failures':failures}),flush=True)
    if failures: sys.exit(1)

if __name__=='__main__': main()
