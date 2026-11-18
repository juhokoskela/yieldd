"""Usage: python3 fixture.py parent|changed /absolute/path/to/GlassEQ"""
import os, subprocess, sys
from pathlib import Path
parent = '44afeded668e014e7436c9d2a6b6855b7527e5a7'
phase, path = sys.argv[1:]
assert phase in ('parent','changed')
os.chdir(path)
def git(*args, **kw):
    return subprocess.check_output(['git',*args], **kw)
assert git('rev-parse','HEAD').decode().strip()==parent
source = Path('Sources/GlassEQCore/ImportedEQTextDetector.swift')
marker = 'yieldd incremental eq export v1'
ts = int(git('show','-s','--format=%ct',parent))
changed_ts = ts+60
if phase=='changed':
    old=source.read_text()
    needle='            || lowercased.contains("filter settings file")'
    assert old.count(needle)==1 and marker not in old
    source.write_text(old.replace(needle,needle+'\n            || lowercased.contains("'+marker+'")'))
    git('add','--',str(source))
    env=dict(os.environ,GIT_AUTHOR_NAME='Benchmark',GIT_COMMITTER_NAME='Benchmark',
             GIT_AUTHOR_EMAIL='benchmark@example.invalid',GIT_COMMITTER_EMAIL='benchmark@example.invalid',
             GIT_AUTHOR_DATE=str(changed_ts)+' +0000',GIT_COMMITTER_DATE=str(changed_ts)+' +0000')
    git('-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','commit','-m','test: recognize one additional EQ export signature',env=env)
    assert git('diff','--name-only',parent,'HEAD').decode().splitlines()==[str(source)]
for f in git('ls-files','-z').split(b'\0'):
    if f:
        stamp=changed_ts if phase=='changed' and os.fsdecode(f)==str(source) else ts
        os.utime(f,(stamp,stamp),follow_symlinks=False)
assert not git('status','--porcelain','--untracked-files=no').strip()
print(git('rev-parse','HEAD').decode().strip())
