"""Export/apply only the data paths an upstream update is allowed to change."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SNAPSHOTS = {'App.tsx', 'api/switches.ts', 'components/GatewaySwitches.tsx', 'lib/discover.ts', 'pages/ServersPage.tsx', 'pages/SettingsPage.tsx', 'state/store.ts'}

def allowed(name):
    p = PurePosixPath(name)
    if p.is_absolute() or '..' in p.parts or '\\' in name or ':' in name:
        return False
    if name in {'module/module.prop', 'module/seed/VERSION', 'module/seed/agent2api-server', 'apk-mod/a2a-mobile-mod.patch', 'scripts/autoupdate/config.json'}:
        return True
    if name.startswith('module/seed/ui/'):
        return not any(x.startswith('.') for x in p.parts)
    return name.startswith('apk-mod/src/') and name[12:] in SNAPSHOTS

def export(out):
    out = Path(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    status = subprocess.check_output(['git', '-C', str(ROOT), 'status', '--porcelain', '-z', '-uall'])
    fields = status.split(b'\0')
    if fields[-1] != b'':
        raise ValueError('Truncated Git status')
    paths = []
    index = 0
    while index < len(fields) - 1:
        header = fields[index]
        index += 1
        if len(header) < 4:
            raise ValueError('Malformed Git status entry')
        state = header[:2].decode('ascii')
        names = [header[3:].decode('utf-8')]
        if 'R' in state or 'C' in state:
            if index >= len(fields) - 1:
                raise ValueError('Rename/copy status lacks source path')
            names.append(fields[index].decode('utf-8'))
            index += 1
        for name in names:
            if allowed(name):
                paths.append(name)
    if not paths:
        raise ValueError('No candidate changes')
    manifest = []
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in sorted(paths):
            p = ROOT/name
            deleted = not p.exists()
            if p.is_symlink():
                raise ValueError('Symlink candidate')
            data = b'' if deleted else p.read_bytes()
            manifest.append({'path': name, 'deleted': deleted, 'sha256': hashlib.sha256(data).hexdigest()})
            if not deleted:
                z.writestr(name, data)
        z.writestr('manifest.json', json.dumps(manifest, indent=2))

def checkpoint_plan(plan):
    return {key: value for key, value in plan.items() if key != 'retry'}


def validate_config(baseline, candidate, plan):
    """Only checkpoint fields may change; the build never chooses trust roots."""
    canonical = checkpoint_plan(plan)
    if not canonical.get('changed') or canonical.get('upstream') != baseline['upstream']:
        raise ValueError('Candidate plan upstream mismatch')
    if canonical['module_revision'] != baseline['module_revision'] + 1:
        raise ValueError('Candidate counters do not advance baseline')
    if canonical.get('republish'):
        # Maintenance rebuild: same upstream/versionCode, one new module revision;
        # reviewed mobile snapshot changes may rebuild the same-version APK track.
        if canonical['version'] != baseline['last_version'] or canonical['commit'] != baseline['last_commit']:
            raise ValueError('Republish must keep the upstream version and commit')
        if canonical['mobile_version_code'] != baseline['mobile_version_code']:
            raise ValueError('Republish must keep the mobile version code')
    elif canonical['mobile_version_code'] <= baseline['mobile_version_code']:
        raise ValueError('Candidate counters do not advance baseline')
    expected = dict(baseline)
    expected.update(last_version=canonical['version'], last_commit=canonical['commit'],
                    module_revision=canonical['module_revision'], mobile_version_code=canonical['mobile_version_code'],
                    last_plan=canonical)
    if candidate != expected:
        raise ValueError('Candidate configuration differs from exact trusted checkpoint')


def apply(archive, plan=None):
    with zipfile.ZipFile(archive) as z:
        if len(z.infolist()) > 10000 or sum(i.file_size for i in z.infolist()) > 512*1024*1024:
            raise ValueError('Candidate limits exceeded')
        if len(z.namelist()) != len(set(z.namelist())):
            raise ValueError('Duplicate candidate entries')
        rows = json.loads(z.read('manifest.json'))
        if len({r['path'] for r in rows}) != len(rows):
            raise ValueError('Duplicate manifest entries')
        expected = {'manifest.json'} | {r['path'] for r in rows if not r['deleted']}
        if set(z.namelist()) != expected:
            raise ValueError('Candidate entries differ from manifest')
        ready = []
        for row in rows:
            name = row['path']
            if not allowed(name):
                raise ValueError('Candidate path outside update allowlist: '+name)
            data = b'' if row['deleted'] else z.read(name)
            if hashlib.sha256(data).hexdigest() != row['sha256']:
                raise ValueError('Candidate hash mismatch')
            p = ROOT/name
            if any(x.is_symlink() for x in [p, *p.parents]):
                raise ValueError('Candidate target is symlink')
            ready.append((p, data, row['deleted']))
        config_path = ROOT/'scripts/autoupdate/config.json'
        configs = [(data, deleted) for p, data, deleted in ready if p == config_path]
        if plan is not None:
            if len(configs) != 1 or configs[0][1]:
                raise ValueError('Candidate must contain checkpoint configuration')
            validate_config(json.loads(config_path.read_text(encoding='utf-8')), json.loads(configs[0][0]), plan)
        elif configs:
            raise ValueError('Applying checkpoint configuration requires a trusted plan')
        for p, data, deleted in ready:
            if deleted:
                p.unlink(missing_ok=True)
            else:
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_bytes(data)
    return rows

def main():
    p = argparse.ArgumentParser()
    p.add_argument('command', choices=['export', 'apply'])
    p.add_argument('archive', type=Path)
    a = p.parse_args()
    (export if a.command == 'export' else apply)(a.archive)

if __name__ == '__main__':
    main()
