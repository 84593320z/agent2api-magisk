"""Fetch complete pinned source with bounded disk use/time; no credentials persist."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--plan', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
plan = json.loads(a.plan.read_text())
config = json.loads((ROOT/'scripts/autoupdate/config.json').read_text())
if plan.get('upstream') != config['upstream'] or not re.fullmatch('[0-9a-f]{40}', plan['commit']):
    raise ValueError('Unexpected upstream identity')
if not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+', plan['tag']):
    raise ValueError('Unexpected upstream tag')
if a.output.exists():
    raise ValueError('Source output already exists')
a.output.mkdir(parents=True)
env = os.environ.copy()
upstream_token = env.pop('UPSTREAM_TOKEN', '')
repo_token = env.pop('GH_TOKEN', '')
token = upstream_token or repo_token
if token:
    env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0='http.https://github.com/.extraheader', GIT_CONFIG_VALUE_0='AUTHORIZATION: basic '+base64.b64encode(('x-access-token:'+token).encode()).decode())

def size():
    return sum(x.stat().st_size for x in a.output.rglob('*') if x.is_file())

def git(*args):
    # Capture no verbose transport output, which can include credential headers.
    process = subprocess.Popen(['git', '-C', str(a.output), *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    deadline = time.monotonic()+600
    try:
        while True:
            try:
                stdout, _ = process.communicate(timeout=1)
                break
            except subprocess.TimeoutExpired:
                if time.monotonic()>deadline or size()>config['max_source_bytes']:
                    raise ValueError('Source transfer exceeds time/disk budget')
        if process.returncode or size()>config['max_source_bytes']:
            raise ValueError('Pinned source command failed or exceeds disk budget')
        return stdout
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate()

git('init')
git('remote', 'add', 'origin', 'https://github.com/'+config['upstream']+'.git')
git('fetch', '--no-tags', 'origin', '+refs/tags/'+plan['tag']+':refs/tags/'+plan['tag'])
if git('rev-parse', plan['tag']+'^{commit}').decode().strip() != plan['commit']:
    raise ValueError('Upstream tag changed after detection')
git('checkout', '--detach', plan['commit'])
print('Pinned complete source fetched:', plan['commit'])
