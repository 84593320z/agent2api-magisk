"""Install verified official v3.4.1 glibc AArch64 binary/UI into this module."""
from pathlib import Path
import hashlib, json, shutil, tarfile
ROOT = Path(__file__).resolve().parent
ARCHIVE = ROOT/'upgrade-evidence/server/official-arm64-3.4.1.tar.gz'
EXPECTED = 'd494e333a697ca9b48f17fc84cd10abdbe5f113a2900aba372fdac3503971e1c'
assert hashlib.sha256(ARCHIVE.read_bytes()).hexdigest() == EXPECTED
compat = json.loads((ROOT/'upgrade-evidence/server/elf-compatibility.json').read_text(encoding='utf-8'))
assert compat['status']=='PASS' and not compat['unresolved']
SEED = ROOT/'module/seed'
# Observe every existing file before replacing the binary/UI. Delete only stale UI
# members beneath the resolved seed/ui directory, never a caller-selected path.
for p in [SEED/'agent2api-server', *(SEED/'ui').rglob('*')]:
    if p.is_file(): p.read_bytes()
with tarfile.open(ARCHIVE,'r:gz') as tar:
    files = {}
    for member in tar.getmembers():
        parts = Path(member.name).parts
        assert not Path(member.name).is_absolute() and '..' not in parts
        assert member.name in ('agent2api-server', 'ui', 'install.sh', 'agent2api.service', 'agent2api.env.example') or member.name.startswith('ui/'), member.name
        assert member.isdir() or member.isfile(), member.name
        if member.isfile() and (member.name == 'agent2api-server' or member.name.startswith('ui/')):
            files[member.name] = tar.extractfile(member).read()
assert hashlib.sha256(files['agent2api-server']).hexdigest()==compat['files']['agent2api-server']['sha256']
assert (SEED/'ui').resolve() == (ROOT/'module/seed/ui').resolve()
for p in sorted((SEED/'ui').rglob('*'),reverse=True):
    if p.is_file() and p.relative_to(SEED).as_posix() not in files: p.unlink()
for name,data in files.items():
    p = SEED/name
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_bytes(data)
manifest = {'upstream':'https://github.com/aimod-cc/Agent2API','tag':'v3.4.1','commit':'3ff4b8215d0d65c3451ca74923e90964ed7dbf59','archive_sha256':EXPECTED,'server_kind':'glibc dynamic AArch64','server_unmodified':True,'dns_resolver_in_existing_libc':'/data/a2a/resolv','files':{n:hashlib.sha256(v).hexdigest() for n,v in sorted(files.items())}}
p = ROOT/'upgrade-evidence/server/seed-manifest.json'
if p.exists(): p.read_bytes()
p.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS exact official binary and UI installed:',len(files),'files; bundled glibc unchanged')
