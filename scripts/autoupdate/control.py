"""Trusted orchestration; never execute code from an upstream checkout with credentials."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import urllib.parse
import urllib.request
import urllib.error
import docs_sync
import versioning

ROOT = Path(__file__).resolve().parents[2]

def version(text):
    """Semver precedence key; a prerelease sorts below its own stable release."""
    try:
        return versioning.key(text)
    except ValueError:
        raise ValueError('Only canonical semantic versions are accepted') from None

def dump(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

def request(url, token=None, data=None, method='GET', binary=False):
    if not url.startswith(('https://api.github.com/', 'https://uploads.github.com/')):
        raise ValueError('Untrusted API endpoint')
    headers = {'Accept': 'application/octet-stream' if binary else 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'agent2api-autoupdate'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    if data is not None:
        headers['Content-Type'] = 'application/json'
        data = json.dumps(data).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers, method=method), timeout=180) as r:
            body = r.read()
            return body if binary else (json.loads(body) if body else None)
    except urllib.error.HTTPError as e:
        raise RuntimeError('GitHub HTTP ' + str(e.code)) from None

def detect(config, token=None, releases=None, ref_lookup=None, allow_prerelease=False):
    """Resolve the newest upstream release; prereleases are opt-in per run."""
    repo = config['upstream']
    base = 'https://api.github.com/repos/' + repo
    releases = releases if releases is not None else request(base + '/releases?per_page=100', token)
    pattern = versioning.VERSION_RE if allow_prerelease else versioning.STABLE_RE
    pool = [r for r in releases if r.get('draft') is False and isinstance(r.get('prerelease'), bool)
            and (allow_prerelease or not r['prerelease']) and pattern.fullmatch(r['tag_name'])]
    if not pool:
        raise ValueError('No stable upstream release' if not allow_prerelease else 'No usable upstream release')
    release = max(pool, key=lambda r: version(r['tag_name']))
    v = version(release['tag_name'])
    if v <= version(config['last_version']):
        return {'changed': False, 'version': config['last_version'], 'tag': release['tag_name']}
    assets = [a for a in release['assets'] if a['name'] == config['asset']]
    if len(assets) != 1:
        raise ValueError('Missing or ambiguous arm64 asset')
    asset = assets[0]
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('Upstream asset lacks pinned SHA-256 digest')
    if not 0 < asset['size'] <= config['max_asset_bytes']:
        raise ValueError('Asset size exceeds configured limit')
    lookup = ref_lookup or (lambda url: request(url, token))
    ref = lookup(base + '/git/ref/tags/' + release['tag_name'])['object']
    for _ in range(5):
        if ref['type'] == 'commit':
            break
        if ref['type'] != 'tag':
            raise ValueError('Tag does not resolve to commit')
        ref = lookup(base + '/git/tags/' + ref['sha'])['object']
    if ref['type'] != 'commit' or not re.fullmatch('[0-9a-f]{40}', ref['sha']):
        raise ValueError('Invalid pinned upstream commit')
    ver = versioning.normalize(release['tag_name'])
    nums = versioning.numbers(release['tag_name'])
    return {'changed': True, 'version': ver, 'tag': release['tag_name'], 'commit': ref['sha'], 'release_id': release['id'], 'published_at': release['published_at'], 'asset_id': asset['id'], 'asset_size': asset['size'], 'asset_sha256': digest[7:], 'upstream': repo, 'prerelease': bool(release['prerelease'] or versioning.prerelease(release['tag_name'])), 'module_revision': config['module_revision'] + 1, 'mobile_version_code': max(nums[0]*10000+nums[1]*100+nums[2], config['mobile_version_code']+1)}

def download(plan, out, token=None):
    if not plan.get('changed'):
        return
    data = request(f"https://api.github.com/repos/{plan['upstream']}/releases/assets/{plan['asset_id']}", token, binary=True)
    if len(data) != plan['asset_size'] or hashlib.sha256(data).hexdigest() != plan['asset_sha256']:
        raise ValueError('Downloaded asset differs from upstream digest/size')
    Path(out).parent.mkdir(parents=True, exist_ok=True)
    Path(out).write_bytes(data)

def release_specs(plan):
    apk = f"Agent2API-{plan['version']}-mod.apk"
    module = f"agent2api-magisk-v{plan['version']}-magisk.{plan['module_revision']}-arm64.zip"
    return {
        f"v{plan['version']}-magisk.{plan['module_revision']}": {module, apk, 'signature.json', 'plan.json', 'provenance.json', 'elf-compatibility.json', 'mobile-build.json', 'full-regression.txt'},
        f"apk-v{plan['version']}-mod": {apk, 'signature.json'},
    }


def release_refs(repo, plan, token=None):
    base = 'https://api.github.com/repos/' + repo
    refs = {}
    for tag in release_specs(plan):
        matches = request(base + '/git/matching-refs/tags/' + tag, token)
        exact = [r for r in matches if r['ref'] == 'refs/tags/' + tag]
        if exact:
            obj = exact[0]['object']
            if obj['type'] != 'commit' or not re.fullmatch('[0-9a-f]{40}', obj['sha']):
                raise ValueError('Release tag must point directly to a commit')
            refs[tag] = obj['sha']
    if len(set(refs.values())) > 1 and not plan.get('republish'):
        raise ValueError('Release tags disagree on checkpoint commit')
    return refs


def releases_complete(config, plan, token=None):
    """Verify exact inventories and downloaded bytes, not merely a checksum filename."""
    base = 'https://api.github.com/repos/' + config['repository']
    specs = release_specs(plan)
    expected_prerelease = bool(plan.get('prerelease'))
    refs = release_refs(config['repository'], plan, token)
    if set(refs) != set(specs):
        return False
    releases = request(base + '/releases?per_page=100', token)
    for tag, names in specs.items():
        matches = [r for r in releases if r['tag_name'] == tag]
        if len(matches) != 1 or matches[0]['draft'] or bool(matches[0]['prerelease']) != expected_prerelease:
            return False
        assets = matches[0]['assets']
        by_name = {a['name']: a for a in assets}
        if len(by_name) != len(assets) or set(by_name) != names | {'SHA256SUMS.txt'}:
            return False
        bodies = {}
        for name, asset in by_name.items():
            digest = asset.get('digest', '')
            if asset.get('state') != 'uploaded' or not isinstance(asset.get('size'), int) or not 0 < asset['size'] <= 512 * 1024 * 1024 or not re.fullmatch('sha256:[0-9a-f]{64}', digest):
                return False
            data = request(base + '/releases/assets/' + str(asset['id']), token, binary=True)
            if len(data) != asset['size'] or hashlib.sha256(data).hexdigest() != digest[7:]:
                return False
            bodies[name] = data
        checks = {}
        try:
            for line in bodies['SHA256SUMS.txt'].decode('utf-8').splitlines():
                match = re.fullmatch(r'([0-9a-f]{64})  ([^/\\\\]+)', line)
                if not match or match[2] in checks:
                    return False
                checks[match[2]] = match[1]
        except UnicodeDecodeError:
            return False
        if set(checks) != names or any(hashlib.sha256(bodies[n]).hexdigest() != checks[n] for n in names):
            return False
        if 'plan.json' in names:
            try:
                if json.loads(bodies['plan.json']) != plan:
                    return False
            except (ValueError, UnicodeDecodeError):
                return False
    return True


def docs_complete(config, plan, token=None):
    """Release assets are not fully published until the deferred entry points land.

    README/update.json are deliberately committed after both Releases.  Treat a
    missing or stale docs commit as incomplete so the next run retries the
    idempotent publisher instead of leaving public update pointers stuck forever.
    """
    base = 'https://api.github.com/repos/' + config['repository']
    branch = urllib.parse.quote(config.get('branch', 'main'), safe='')

    def content(name):
        row = request(base + '/contents/' + name + '?ref=' + branch, token)
        if (not isinstance(row, dict) or row.get('type') != 'file'
                or row.get('encoding') != 'base64' or not isinstance(row.get('content'), str)):
            raise ValueError('Published entry point is not a readable file: ' + name)
        return base64.b64decode(row['content']).decode('utf-8')

    try:
        readme = content('README.md')
        document = json.loads(content('update.json'))
        if not isinstance(document, dict):
            return False
        if docs_sync.latest_block(plan, config['repository']) not in readme:
            return False
        version = plan['version']
        revision = plan['module_revision']
        tag = f'v{version}-magisk.{revision}'
        module = f'agent2api-magisk-v{version}-magisk.{revision}-arm64.zip'
        release = request(base + '/releases/tags/' + tag, token)
        assets = [a for a in release['assets'] if a['name'] == module]
        if len(assets) != 1:
            return False
        digest = assets[0].get('digest', '')
        expected = {
            'version': f'v{version} (magisk.{revision})',
            'zipUrl': f"https://github.com/{config['repository']}/releases/download/{tag}/{module}",
            'changelog': f"https://github.com/{config['repository']}/releases/tag/{tag}",
            'sha256': digest[7:] if digest.startswith('sha256:') else '',
        }
        return (all(document.get(k) == v for k, v in expected.items())
                and type(document.get('versionCode')) is int and document['versionCode'] > 0
                and re.fullmatch('[0-9a-f]{64}', expected['sha256']) is not None)
    except (KeyError, TypeError, ValueError, UnicodeError) as exc:
        # Malformed content is an incomplete publish, not a success; transport
        # errors from request() deliberately propagate and fail the detect job.
        print('Published documentation check failed:', exc)
        return False


def select_plan(config, token=None, upstream_token=None, allow_prerelease=False):
    previous = config.get('last_plan')
    if previous and (not releases_complete(config, previous, token)
                     or not docs_complete(config, previous, token)):
        return dict(previous, retry=True)
    plan = detect(config, upstream_token or token, allow_prerelease=allow_prerelease)
    if plan.get('changed'):
        plan['run_id'] = os.getenv('GITHUB_RUN_ID', '')
    return plan


def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['detect', 'download', 'advance'])
    p.add_argument('--config', type=Path, default=ROOT/'scripts/autoupdate/config.json')
    p.add_argument('--plan', type=Path, default=Path('automation-out/plan.json'))
    p.add_argument('--output', default='automation-out/server.tar.gz')
    a = p.parse_args()
    config = json.loads(a.config.read_text())
    if a.command == 'detect':
        allow = os.getenv('ALLOW_PRERELEASE', '').strip().lower() == 'true'
        plan = select_plan(config, os.getenv('GH_TOKEN'), os.getenv('UPSTREAM_TOKEN'), allow_prerelease=allow)
        dump(a.plan, plan)
        if os.getenv('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a', encoding='utf-8') as f:
                f.write('changed=' + str(plan['changed']).lower() + '\n')
                f.write('retry=' + str(bool(plan.get('retry'))).lower() + '\n')
                f.write('prerelease=' + str(bool(plan.get('prerelease'))).lower() + '\n')
                f.write('run_id=' + str(plan.get('run_id', '')) + '\n')
        print(json.dumps(plan))
    else:
        plan = json.loads(a.plan.read_text())
        if a.command == 'download':
            download(plan, a.output, os.getenv('UPSTREAM_TOKEN') or os.getenv('GH_TOKEN'))
        else:
            assert plan['changed']
            if plan.get('retry'):
                assert plan['version']==config['last_version'] and plan['commit']==config['last_commit']
            elif plan.get('republish'):
                # Module-only rebuild of the version already recorded in the checkpoint.
                assert plan['version']==config['last_version'] and plan['commit']==config['last_commit']
                assert plan['module_revision']==config['module_revision']+1
                assert plan['mobile_version_code']==config['mobile_version_code']
                for key in ('module_revision', 'mobile_version_code'):
                    config[key] = plan[key]
                config['last_plan'] = plan
            else:
                assert version(plan['version']) > version(config['last_version'])
                for key in ('module_revision', 'mobile_version_code'):
                    assert plan[key] > config[key]
                    config[key] = plan[key]
                config.update(last_version=plan['version'], last_commit=plan['commit'])
                config['last_plan'] = plan
            dump(a.config, config)

if __name__ == '__main__':
    main()
