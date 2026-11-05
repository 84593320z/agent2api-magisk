"""Credential-free build coordinator, consumed by the unprivileged job only."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from control import ROOT

p = argparse.ArgumentParser()
p.add_argument('--plan', type=Path, required=True)
p.add_argument('--source', type=Path, required=True)
p.add_argument('--archive', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--smoke', choices=['true','false'], default='false')
a = p.parse_args()
plan = json.loads(a.plan.read_text())
out = a.output.resolve()
def run(script, *args):
    subprocess.run([sys.executable, str(ROOT/'scripts/autoupdate'/script), *map(str,args)], check=True)
with tempfile.TemporaryDirectory(prefix='a2a-mobile-ci-') as temp:
    prep, mobile = Path(temp)/'prepared', Path(temp)/'mobile'
    run('mobile.py', 'prepare', '--source', a.source.resolve(), '--tag', plan['tag'], '--commit', plan['commit'], '--version-code', plan['mobile_version_code'], '--output', prep)
    run('mobile.py', 'build', '--prepared', prep, '--output', mobile)
    for name in ('mobile-unsigned.apk', 'mobile-build.json'):
        shutil.copyfile(mobile/name, out/name)
# Server integration validates before replacing the repo seed or metadata.
server = out/'server-build'
run('server.py', '--archive', a.archive.resolve(), '--sha256', plan['asset_sha256'], '--version', plan['version'], '--built', plan['published_at'], '--module-revision', plan['module_revision'], '--commit', plan['commit'], '--output', server)
for file in (server/'out').glob('*.zip'):
    shutil.copyfile(file, out/file.name)
for name in ('provenance.json', 'elf-compatibility.json'):
    shutil.copyfile(server/name, out/name)
if a.smoke != 'true':
    run('control.py', 'advance', '--plan', a.plan.resolve())
print('Unsigned candidates built and verified')
