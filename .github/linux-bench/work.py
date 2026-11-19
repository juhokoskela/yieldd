import hashlib, json, os, subprocess, sys, time
from pathlib import Path
from contextlib import contextmanager
root=Path(os.environ["GITHUB_WORKSPACE"])/"GlassEQServer"
out=Path(os.environ["RUNNER_TEMP"])/"linux-server-evidence"
out.mkdir(exist_ok=True);os.chdir(root)
os.environ["PATH"]="/usr/local/go/bin:"+os.environ["PATH"]
stage=os.environ["BENCH_STAGE"];parent=stage.endswith("-seed");warm=stage.endswith(("-r1","-r2"))
cache=Path("/mnt/yieldd-cache");b=cache/"build";m=cache/"modules";marker=b/"yieldd-glasseqserver-parent"
store=out/"guest.json"
report=json.loads(store.read_text()) if store.exists() else {"stage":stage,"durations":{}}
def record():store.write_text(json.dumps(report,indent=2)+"\n")
def capture(*cmd):return subprocess.check_output(cmd,stderr=subprocess.STDOUT,text=True).strip()
def run(*cmd):subprocess.run(cmd,check=True)
@contextmanager
def clock(name):
    start=time.perf_counter()
    try:yield
    finally:
        report["durations"][name]=time.perf_counter()-start;record()
def digest(p):return hashlib.file_digest(p.open("rb"),"sha256").hexdigest() if hasattr(hashlib,"file_digest") else hashlib.sha256(p.read_bytes()).hexdigest()
def verify_binary(cmd):
    result=subprocess.run([*cmd,"__yieldd_benchmark_invalid_command__"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    msg=json.loads(result.stdout.strip().splitlines()[-1])["msg"]
    assert (result.returncode,msg)==(1,"invalid command" if parent else "unknown GlassEQServer command"),(result.returncode,msg)
    return msg
def sizes():
    return {p.name:int(capture("du","-sb",str(p)).split()[0]) if p.exists() else 0 for p in (b,m)}
if sys.argv[1]=="prepare":
    base="87cd5a17938c2b9b6036a4d37b0b583406989261"
    assert capture("git","rev-parse","HEAD")==base
    if not parent:
        p=Path("cmd/glasseqserver/main.go")
        s=p.read_text();old='logger.Error("invalid command", "error", "usage: glasseqserver [check-stripe-catalog]")'
        assert s.count(old)==1
        p.write_text(s.replace(old,old.replace("invalid command","unknown GlassEQServer command")))
        ts=str(int(capture("git","log","-1","--format=%ct"))+60)+" +0000"
        env={**os.environ,"GIT_AUTHOR_DATE":ts,"GIT_COMMITTER_DATE":ts}
        subprocess.run(["git","-c","user.name=yieldd benchmark","-c","user.email=benchmark@localhost","commit","-am","test: distinguish the changed server diagnostic"],check=True,env=env)
        assert capture("git","diff","--name-only",base,"HEAD")=="cmd/glasseqserver/main.go"
    report.update(parent_source=base,source=capture("git","rev-parse","HEAD"),tree=capture("git","rev-parse","HEAD^{tree}"),workspace=str(root),go=capture("go","version"),kernel=capture("uname","-srmo"),cpus=int(capture("nproc")),memory=Path("/proc/meminfo").read_text().splitlines()[0])
    assert report["go"]=="go version go1.27.4 linux/arm64" and report["cpus"]==4,report
    if not stage.startswith("native"):
        run("sudo","install","-d","-m","0755","-o","runner","-g","runner",str(cache))
    report["python"]=sys.version
    record()
elif sys.argv[1]=="work":
    with clock("cache_checks"):
        if stage.startswith("native"):
            assert capture("findmnt","-n","-o","FSTYPE","--mountpoint",str(cache))=="ext4"
            assert os.environ["YIELDD_CACHE_PATH"]==str(cache)
        else:assert bool(os.environ.get("ARCHIVE_HIT")=="true")==warm
        report["archive_hit"]=os.environ.get("ARCHIVE_HIT","");report["parent_marker"]=marker.read_text() if marker.exists() else None
        assert report["parent_marker"]==("parent "+report["parent_source"] if warm else None)
        b.mkdir(exist_ok=True);m.mkdir(exist_ok=True)
        report["restored_bytes"]=sizes()
    pg="postgres:18-alpine@sha256:d3e1620b530c944afa6e887d22eb899824da68e19c52024bf98f5220c88a65b2"
    goose="juhokoskela/goose:v3.27.3@sha256:db4be381f2173bfd8994b9ca03e2fa2f8d7692ac3cef4aa5e2059db3e760cc3d"
    tag="local/glasseq-benchmark:proof"
    with clock("postgres_migrate"):
        for _ in range(90):
            if subprocess.run(["docker","info"],capture_output=True).returncode==0:break
            time.sleep(1)
        report["docker"]=capture("docker","info","--format","{{.ServerVersion}} {{.Driver}}")
        report["input_images"]=capture("docker","image","ls","--format","{{.Repository}} {{.Digest}}").splitlines()
        assert len(report["input_images"])==4,report["input_images"]
        run("docker","run","--pull=never","-d","--name","glasseq-postgres","--network","host","-e","POSTGRES_PASSWORD=glasseq","-e","POSTGRES_USER=glasseq","-e","POSTGRES_DB=glasseq",pg)
        for _ in range(45):
            if subprocess.run(["docker","exec","glasseq-postgres","psql","-U","glasseq","-d","glasseq","-Atc","select 1"],capture_output=True).returncode==0:break
            time.sleep(1)
        run("docker","run","--pull=never","--rm","--network","host","-v",str(root/"migrations")+":/migrations:ro","-e","GOOSE_DRIVER=postgres","-e","GOOSE_DBSTRING="+os.environ["GLASSEQ_TEST_DATABASE_URL"],goose,"up")
        report["migration"]=capture("docker","exec","glasseq-postgres","psql","-U","glasseq","-d","glasseq","-Atc","SELECT version_id FROM goose_db_version ORDER BY id DESC LIMIT 1")
        assert report["migration"]=="8"
    with clock("test_race"):
        with (out/"test.jsonl").open("w") as log:subprocess.run(["go","test","-json","-race","-p","1","-count=1","./..."],stdout=log,check=True)
    tests=[json.loads(line) for line in (out/"test.jsonl").read_text().splitlines()]
    report["postgres_tests"]=sorted(t["Test"] for t in tests if t.get("Action")=="pass" and "PostgreSQL" in t.get("Test",""))
    report["tests_passed"]=sum(t.get("Action")=="pass" and "Test" in t for t in tests)
    assert report["postgres_tests"] and not any(t.get("Action")=="skip" and "PostgreSQL" in t.get("Test","") for t in tests)
    with clock("vet"):run("go","vet","./...")
    with clock("go_build_proof"):
        exe=Path("/tmp/yieldd-benchmark-service")
        run("go","build","-trimpath","-o",str(exe),"./cmd/glasseqserver")
        report["go_binary_sha256"]=digest(exe);report["go_diagnostic"]=verify_binary([str(exe)])
    with clock("docker_build"):
        with (out/"docker-build.log").open("w") as log:subprocess.run(["docker","build","--no-cache","--progress=plain","--network=host","--build-arg","SOURCE_REVISION="+report["source"],"-t",tag,"."],stdout=log,stderr=subprocess.STDOUT,check=True)
    with clock("docker_proof"):
        assert capture("docker","image","inspect",tag,"--format",'{{index .Config.Labels "org.opencontainers.image.revision"}}')==report["source"]
        report["docker_diagnostic"]=verify_binary(["docker","run","--rm","--network=none",tag])
        cid=capture("docker","create",tag)
        file=Path("/tmp/yieldd-packaged-service")
        run("docker","cp",cid+":/usr/local/bin/glasseqserver",str(file));report["docker_binary_sha256"]=digest(file);run("docker","rm",cid)
    marker.write_text(("parent " if parent else "changed ")+report["source"])
    with clock("output_inventory"):report["saved_bytes"]=sizes()
    print(json.dumps(report))
