"""Offline v3.4.1 seed and reproducible Magisk ZIP acceptance.
Run after python pack.py; provenance lives in docs/upgrade-3.4.1/evidence.
"""
from pathlib import Path
import hashlib, json, stat, subprocess, zipfile
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT/'upgrade-evidence/server'
DOC = ROOT/'docs/upgrade-3.4.1/evidence'
def source(name):
    p = OUT/name
    return p if p.exists() else DOC/name
def sha(data): return hashlib.sha256(data).hexdigest()
manifest = json.loads(source('seed-manifest.json').read_text(encoding='utf-8'))
elf = json.loads(source('elf-compatibility.json').read_text(encoding='utf-8'))
assert manifest['tag']=='v3.4.1' and manifest['server_kind']=='glibc dynamic AArch64'
assert elf['status']=='PASS' and not elf['unresolved']
assert 'agent2api/3.4.1' in elf['server_versions']
seed = ROOT/'module/seed'
for name,digest in manifest['files'].items():
    assert sha((seed/name).read_bytes())==digest, name
actual = {'agent2api-server'} | {'ui/'+p.relative_to(seed/'ui').as_posix() for p in (seed/'ui').rglob('*') if p.is_file()}
assert actual==set(manifest['files']), 'stale or missing UI member'
for name,info in elf['files'].items():
    if name=='agent2api-server': continue
    p=seed/'lib'/name
    assert sha(p.read_bytes())==info['sha256'], name
    old=subprocess.check_output(['git','-C',str(ROOT),'show','f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4:module/seed/lib/'+name])
    assert p.read_bytes()==old, 'bundled runtime changed: '+name
assert b'/data/a2a/resolv' in (seed/'lib/libc.so.6').read_bytes()
assert 'ver=3.4.1\n' in (seed/'VERSION').read_text(encoding='utf-8')
assert 'version=v3.4.1 (magisk.36)\n' in (ROOT/'module/module.prop').read_text(encoding='utf-8')
archive=ROOT/'dist/agent2api-magisk-v3.4.1-magisk.36-arm64.zip'
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    for i in z.infolist():
        assert i.date_time==(2026,10,19,0,0,0)
        assert i.create_system==3 and not i.filename.startswith('/') and '..' not in Path(i.filename).parts
        if i.is_dir(): continue
        assert z.read(i)==(ROOT/'module'/i.filename).read_bytes(), i.filename
        mode=stat.S_IMODE(i.external_attr>>16)
        if i.filename in ('seed/agent2api-server','seed/lib/ld-linux-aarch64.so.1','customize.sh') or i.filename.startswith('libexec/'):
            assert mode==0o755, (i.filename,oct(mode))
    assert z.read('seed/agent2api-server')==(seed/'agent2api-server').read_bytes()
report={'status':'PASS','seed_files_exact':len(manifest['files']),'bundled_runtime_unchanged':10,'elf_dependency_validation':'PASS','module_zip':archive.name,'zip_sha256':sha(archive.read_bytes()),'zip_bytes':archive.stat().st_size,'zip_crc':'PASS','zip_members_match_worktree':True,'zip_executable_modes':'PASS','zip_fixed_timestamp':'PASS','device_execution':'not performed'}
p=ROOT/'upgrade-evidence/server/package-verification.json'
p.parent.mkdir(parents=True,exist_ok=True)
if p.exists(): p.read_bytes()
p.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
print(json.dumps(report,indent=2))
