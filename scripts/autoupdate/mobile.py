#!/usr/bin/env python3
"""Rebase the mobile overlay and build a credential-free, unsigned APK.

prepare publishes source/ and mobile-prepare.json; build consumes that directory.
Only prepare refreshes the seven repository snapshots and the reusable patch.
All subprocesses use argument arrays, never shell interpolation. No signer is run.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

REPO = Path(__file__).resolve().parents[2]
MOBILE = 'desktop-tauri/mobile'
SRC = MOBILE + '/src/'
SNAPSHOTS = ('App.tsx', 'api/switches.ts', 'components/GatewaySwitches.tsx',
             'lib/discover.ts', 'pages/ServersPage.tsx', 'pages/SettingsPage.tsx',
             'state/store.ts')
EXPECTED_CERT = 'd0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f'
PACKAGE = 'com.agent2api.mobile.mod'


class MobileError(RuntimeError):
    """A fail-closed preparation or build validation error."""


def safe_diagnostic(data, env=None):
    """Bounded, terminal-safe failure evidence; never print credential values."""
    text = data.decode('utf-8', errors='replace') if isinstance(data, bytes) else str(data)
    # Scrub before taking a tail, so truncation cannot split a known secret.
    sensitive = r'(?:TOKEN|SECRET|PASSWORD|PASSWD|PASSPHRASE|CREDENTIAL|PRIVATE.?KEY|API.?KEY|ACCESS.?KEY|KEYSTORE|SIGNING|STORE_PASS|KEY_PASS|AUTH)'
    values = {str(value) for mapping in (os.environ, env or {}) for key, value in mapping.items()
              if value and re.search(sensitive, key, re.I)}
    for value in sorted(values, key=len, reverse=True):
        text = text.replace(value, '[REDACTED]')
    text = re.sub(r'-----BEGIN [^-]*PRIVATE KEY-----.*?(?:-----END [^-]*PRIVATE KEY-----|\Z)',
                  '[REDACTED PRIVATE KEY]', text, flags=re.S)
    text = re.sub(r'(?im)^.*(?:authorization\s*:|(?:' + sensitive + r')\w*\s*[:=]).*$',
                  '[REDACTED credential line]', text)
    # Strip URL userinfo and the entire query/fragment, including signed URLs.
    text = re.sub(r'(?i)(https?://)[^/\s@]+@', r'\1[REDACTED]@', text)
    text = re.sub(r'(?i)(https?://[^\s?#]+)[?#][^\s]*', r'\1?[REDACTED]', text)
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    text = ''.join(ch for ch in text if ch in '\n\t' or (ord(ch) >= 32 and ord(ch) != 127))
    return ('[earlier output truncated]\n' if len(text) > 12000 else '') + text[-12000:]


def run(args, cwd=None, env=None, check=True):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        # Do not echo argv: arguments may carry credentials. Retain compiler/git
        # evidence instead of a bare exit code, with bounded redacted streams.
        label = Path(str(args[0])).name
        if label.lower() in {'git', 'git.exe'}:
            operation = next((str(a) for a in args[1:] if str(a) in
                              {'clone', 'checkout', 'apply', 'diff', 'config', 'reset', 'rev-parse'}), '')
            label += ' ' + operation
        details = '\n'.join(name + ':\n' + safe_diagnostic(data, env)
                            for name, data in (('stdout', result.stdout), ('stderr', result.stderr)) if data)
        raise MobileError(f'{label} failed (exit {result.returncode})' + ('\n' + details if details else ''))
    return result


def git(source, *args, check=True):
    return run(['git', '-C', source, *args], check=check)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def version(tag, code):
    if not re.fullmatch(r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'
                        r'(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?', tag):
        raise MobileError('tag must be vX.Y.Z or vX.Y.Z-pre (canonical numeric release)')
    if isinstance(code, bool) or not isinstance(code, int) or not 1 <= code <= 2100000000:
        raise MobileError('version-code must be an integer in 1..2100000000')
    return tag[1:]


def inside(path, root):
    return path == root or root in path.parents


def output_path(value, *protected):
    out = Path(value).absolute()
    if any(p.is_symlink() for p in (out, *out.parents)):
        raise MobileError('output path contains a symlink')
    out = out.resolve()
    for root in protected:
        root = Path(root).resolve()
        if inside(out, root) or inside(root, out):
            raise MobileError('output overlaps repository or source')
    if out.exists():
        raise MobileError('output must not exist; use a fresh directory')
    return out


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise MobileError('expected regular file: ' + path.name)
    return path.read_bytes()


def validate_patch(data):
    text = data.decode('utf-8').replace('\r\n', '\n')
    headers = re.findall(r'^diff --git a/(\S+) b/(\S+)$', text, re.M)
    for marker in re.findall(r'^(?:---|\+\+\+) (.+)$', text, re.M):
        if marker != '/dev/null' and marker not in {prefix + SRC + name for prefix in ('a/', 'b/') for name in SNAPSHOTS}:
            raise MobileError('patch file marker escapes mobile overlay paths')
    if not headers or len(headers) != text.count('diff --git '):
        raise MobileError('patch has unsupported or missing paths')
    paths = []
    allowed = {SRC + name for name in SNAPSHOTS}
    for old, new in headers:
        if old != new or old not in allowed or old in paths:
            raise MobileError('patch escapes the seven mobile overlay paths')
        paths.append(old)
    if re.search(r'^(?:old mode|new mode|deleted file mode|rename |copy |GIT binary patch)', text, re.M):
        raise MobileError('patch may only modify/add ordinary source text')
    return paths


def validate_switches(source):
    api = regular(source / SRC / 'api/switches.ts').decode('utf-8')
    ui = regular(source / SRC / 'components/GatewaySwitches.tsx').decode('utf-8')
    required_api = ("typeof next !== 'boolean'", 'if (pick(body, def) !== next)',
                    "typeof raw === 'boolean' ? raw : undefined")
    required_ui = ('const epoch = useRef(0)', 'mine !== epoch.current',
                   'const protectedIds = new Set(pending.current.keys())',
                   'pending.current.delete(id)', 'delete merged[id]',
                   'chain.current = chain.current.then(async () =>')
    if any(token not in api for token in required_api) or any(token not in ui for token in required_ui):
        raise MobileError('GatewaySwitches strict echo/epoch safeguards changed')
    if ui.count('++epoch.current') < 3 or ui.count('mine !== epoch.current') < 2:
        raise MobileError('GatewaySwitches write/read epoch barriers changed')


def read_metadata(prepared):
    meta = json.loads(regular(prepared / 'mobile-prepare.json'))
    if meta.get('schema') != 1:
        raise MobileError('unsupported mobile prepare schema')
    if version(meta['tag'], meta['version_code']) != meta['version']:
        raise MobileError('prepare version/tag mismatch')
    if not re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', meta['source_commit']):
        raise MobileError('prepare commit must be a full SHA')
    return meta


def prepare(source, tag, commit, version_code, output, repo=REPO):
    release = version(tag, version_code)
    source = Path(source).resolve()
    repo = Path(repo).resolve()
    out = output_path(output, source, repo)
    if not re.fullmatch(r'[0-9a-fA-F]{40}|[0-9a-fA-F]{64}', commit):
        raise MobileError('commit must be a full SHA')
    commit = commit.lower()
    if git(source, 'rev-parse', '--is-shallow-repository').stdout.strip() != b'false':
        raise MobileError('source must be a complete, non-shallow upstream clone')
    if git(source, 'rev-parse', '--is-bare-repository').stdout.strip() != b'false':
        raise MobileError('source must be a non-bare upstream clone')
    config = git(source, 'config', '--get', 'extensions.partialClone', check=False)
    promisor = git(source, 'config', '--get-regexp', r'^remote\..*\.promisor$', check=False)
    if config.returncode == 0 or promisor.returncode == 0:
        raise MobileError('partial clones are not accepted')
    if git(source, 'rev-parse', '--verify', 'refs/tags/' + tag + '^{commit}').stdout.decode().strip() != commit:
        raise MobileError('tag does not resolve to requested commit')
    patch_path = repo / 'apk-mod/a2a-mobile-mod.patch'
    original = {patch_path: regular(patch_path)}
    paths = validate_patch(original[patch_path])
    for name in SNAPSHOTS:
        dest = repo / 'apk-mod/src' / name
        original[dest] = regular(dest)  # read before any replacement
    out.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix='.mobile-prepare-', dir=out.parent))
    try:
        work = staging / 'source'
        run(['git', '-c', 'core.hooksPath=', 'clone', '--no-hardlinks', '--no-checkout', '--', source, work])
        git(work, 'config', 'core.autocrlf', 'false')
        git(work, 'config', 'core.hooksPath', '')
        git(work, 'checkout', '--detach', commit)
        # Read only committed data; an unclean source clone never contaminates output.
        patch_copy = staging / 'input.patch'
        patch_copy.write_bytes(original[patch_path])
        direct = git(work, 'apply', '--check', patch_copy, check=False)
        if direct.returncode:
            git(work, 'apply', '--3way', '--check', patch_copy)
        git(work, 'apply', '--3way', patch_copy)
        if git(work, 'ls-files', '-u').stdout:
            raise MobileError('mobile patch conflict; nothing published')
        validate_switches(work)
        changed = git(work, 'diff', '--cached', '--name-only', commit).stdout.decode().splitlines()
        if not changed or set(changed) - set(paths):
            raise MobileError('mobile patch changed unexpected paths')
        refreshed = git(work, 'diff', '--cached', '--binary', '--full-index', commit, '--', SRC).stdout
        validate_patch(refreshed)
        regenerated = staging / 'a2a-mobile-mod.patch'
        regenerated.write_bytes(refreshed)
        git(work, 'apply', '--reverse', '--check', regenerated)
        # Prove this replacement patch starts at the new commit, not the old base.
        git(work, 'reset', '--hard', commit)
        git(work, 'apply', '--check', regenerated)
        git(work, 'apply', '--3way', regenerated)
        validate_switches(work)
        updates = {patch_path: refreshed}
        snapshots = {}
        for name in SNAPSHOTS:
            data = regular(work / SRC / name)
            updates[repo / 'apk-mod/src' / name] = data
            snapshots[name] = sha(data)
        manifest = {'schema': 1, 'source_commit': commit, 'upstream_commit': commit,
                    'tag': tag, 'version': release, 'version_code': version_code,
                    'source': 'source', 'patch_sha256': sha(refreshed),
                    'snapshots': snapshots, 'expected_certificate_sha256': EXPECTED_CERT}
        (staging / 'mobile-prepare.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        patch_copy.unlink()
        # Concurrent edits are preserved: fail before publishing if the tree changed.
        if any(regular(path) != data for path, data in original.items()):
            raise MobileError('repository mobile overlay changed during prepare')
        written = []
        try:
            for path, data in updates.items():
                path.write_bytes(data)
                written.append(path)
            staging.rename(out)
        except BaseException:
            for path in reversed(written):
                path.write_bytes(original[path])
            raise
        return manifest
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def unsigned_apk(path):
    """Reject v1 signatures and APK Signing Block (v2/v3) without a signer."""
    with zipfile.ZipFile(path) as archive:
        for name in archive.namelist():
            if re.match(r'^META-INF/[^/]+\.(?:RSA|DSA|EC|SF)$', name, re.I):
                raise MobileError('release APK contains a v1 signature')
        central = archive.start_dir
    with path.open('rb') as stream:
        if central >= 24:
            stream.seek(central - 24)
            footer = stream.read(24)
            if footer[8:] == b'APK Sig Block 42':
                raise MobileError('release APK contains an APK signing block')


def verify_assets(apk, dist):
    """Compare actual fresh dist bytes, not an assumed fixed resource count."""
    dist = Path(dist)
    files = {}
    for path in sorted(dist.rglob('*')):
        if path.is_symlink():
            raise MobileError('web dist contains a symlink')
        if path.is_file():
            files[path.relative_to(dist).as_posix()] = path
    if not {'index.html', 'mobile.js', 'mobile.css'}.issubset(files):
        raise MobileError('fresh native dist is incomplete')
    results = []
    with zipfile.ZipFile(apk) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise MobileError('APK contains duplicate ZIP paths')
        public = {n[len('assets/public/'):] for n in archive.namelist()
                  if n.startswith('assets/public/') and not n.endswith('/')}
        # Capacitor injects these two framework stubs during sync, outside Vite dist.
        generated = public - set(files)
        if generated - {'cordova.js', 'cordova_plugins.js'} or set(files) - public:
            raise MobileError('APK public asset inventory differs from fresh dist')
        for rel, path in files.items():
            actual = regular(path)
            if archive.read('assets/public/' + rel) != actual:
                raise MobileError('APK web asset mismatch: ' + rel)
            results.append({'asset': rel, 'bytes': len(actual), 'sha256': sha(actual)})
        for name in generated:
            if archive.read('assets/public/' + name).strip():
                raise MobileError('unexpected nonempty Capacitor Cordova stub')
        plugins = json.loads(archive.read('assets/capacitor.plugins.json'))
        if not {'@capacitor/app', '@capacitor/keyboard'}.issubset({p['pkg'] for p in plugins}):
            raise MobileError('required Capacitor plugins missing')
        if archive.getinfo('resources.arsc').compress_type != zipfile.ZIP_STORED:
            raise MobileError('resources.arsc must be stored, not compressed')
    return {'all_web_assets_match': True, 'asset_count': len(results), 'assets': results,
            'capacitor_generated_assets': sorted(generated), 'native_plugins': plugins}


def gradle_init():
    return '''// Unsigned CI only: no credential values are read or generated.
gradle.beforeProject { project ->
    project.pluginManager.withPlugin('com.android.application') {
        project.androidComponents.finalizeDsl { android ->
            android.defaultConfig.versionName = project.findProperty('mobileVersionName')
            android.defaultConfig.versionCode = project.findProperty('mobileVersionCode').toInteger()
            android.compileSdk = 36
            android.defaultConfig.targetSdk = 36
            android.buildTypes.release.signingConfig = null
        }
    }
}
'''


def build(prepared, output, *, tag=None, commit=None, version_code=None):
    if sys.platform != 'linux':
        raise MobileError('build requires a Linux runner')
    prepared = Path(prepared).resolve()
    meta = read_metadata(prepared)
    for actual, expected in ((tag, meta['tag']), (commit, meta['source_commit']),
                             (version_code, meta['version_code'])):
        if actual is not None and actual != expected:
            raise MobileError('build parameters differ from prepared source')
    source = prepared / 'source'
    out = output_path(output, prepared, REPO)
    if git(source, 'rev-parse', 'HEAD').stdout.decode().strip() != meta['source_commit']:
        raise MobileError('prepared source commit changed')
    if sha(regular(prepared / 'a2a-mobile-mod.patch')) != meta['patch_sha256']:
        raise MobileError('prepared patch digest changed')
    staged = git(source, 'diff', '--cached', '--binary', '--full-index', 'HEAD', '--', SRC).stdout
    if sha(staged) != meta['patch_sha256'] or git(source, 'diff', '--name-only').stdout:
        raise MobileError('prepared source differs from validated patch')
    for rel, digest in meta['snapshots'].items():
        if rel not in SNAPSHOTS or sha(regular(source / SRC / rel)) != digest:
            raise MobileError('prepared snapshot digest changed')
    if set(meta['snapshots']) != set(SNAPSHOTS):
        raise MobileError('prepare requires all seven snapshots')
    validate_switches(source)
    env = {k: v for k, v in os.environ.items()
           if not re.search(r'(?:KEYSTORE|SIGNING|STORE_PASS|KEY_PASS)', k, re.I)}
    env['ORG_GRADLE_PROJECT_devAppIdSuffix'] = '.mod'
    java_home = env.get('JAVA_HOME')
    java_command = str(Path(java_home) / 'bin/java') if java_home else 'java'
    if java_home:
        env['PATH'] = str(Path(java_home) / 'bin') + os.pathsep + env.get('PATH', '')
    java = run([java_command, '-version'], env=env)
    if not re.search(rb'(?:openjdk|java) version "21(?:\.|\")', java.stderr + java.stdout):
        raise MobileError('build requires JDK 21 on PATH')
    sdk_value = env.get('ANDROID_SDK_ROOT') or env.get('ANDROID_HOME')
    if not sdk_value:
        raise MobileError('ANDROID_SDK_ROOT or ANDROID_HOME is required')
    sdk = Path(sdk_value).resolve()
    if not (sdk / 'platforms/android-36/android.jar').is_file():
        raise MobileError('Android SDK platform 36 is required')
    aapt = sdk / 'build-tools/36.0.0/aapt2'
    if not aapt.is_file():
        raise MobileError('Android SDK build-tools 36.0.0 is required')
    out.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.mobile-build-', dir=out.parent))
    try:
        # Build a new committed-source copy; never import untracked signing material.
        work = stage / 'work'
        run(['git', '-c', 'core.hooksPath=', 'clone', '--no-checkout', '--no-hardlinks', '--', source, work])
        git(work, 'config', 'core.autocrlf', 'false')
        git(work, 'config', 'core.hooksPath', '')
        git(work, 'checkout', '--detach', meta['source_commit'])
        git(work, 'apply', '--3way', prepared / 'a2a-mobile-mod.patch')
        mobile = work / MOBILE
        android = mobile / 'android'
        props = android / 'keystore.properties'
        if props.exists():
            raise MobileError('upstream must not track keystore.properties')
        if any(p.suffix.lower() in {'.jks', '.keystore', '.p12', '.pfx'} for p in android.rglob('*')):
            raise MobileError('upstream Android tree contains signing material')
        pkg_path = mobile / 'package.json'
        pkg = json.loads(regular(pkg_path))
        pkg['version'] = meta['version']
        pkg_path.write_text(json.dumps(pkg, indent=2) + '\n', encoding='utf-8')
        # npm ci checks root lockfile metadata; keep version-only metadata aligned.
        lock_path = mobile / 'package-lock.json'
        lock = json.loads(regular(lock_path))
        lock['version'] = meta['version']
        if '' in lock.get('packages', {}):
            lock['packages']['']['version'] = meta['version']
        lock_path.write_text(json.dumps(lock, indent=2) + '\n', encoding='utf-8')
        # Upstream lockfiles pin a public mirror that intermittently answers 504;
        # retry before failing the whole sync.
        npm_ci = ['npm', 'ci', '--no-audit', '--no-fund',
                  '--fetch-retries=5', '--fetch-retry-mintimeout=10000',
                  '--fetch-retry-maxtimeout=120000']
        run(npm_ci, cwd=mobile, env=env)
        run(npm_ci, cwd=mobile.parent / 'ui-kit', env=env)
        dist = mobile / 'android-www'
        if dist.exists():
            # Exact isolated generated target, never the caller's tree.
            if dist.is_symlink():
                raise MobileError('native dist path is a symlink')
            shutil.rmtree(dist)
        run(['npm', 'run', 'build:native'], cwd=mobile, env=env)
        cap = mobile / 'node_modules/@capacitor/cli/bin/capacitor'
        run(['node', cap, 'sync', 'android'], cwd=mobile, env=env)
        # The upstream guard requires existence only. This file has zero properties.
        props.write_text('# Unsigned build; no credentials.\n', encoding='ascii')
        init = stage / 'unsigned.init.gradle'
        init.write_text(gradle_init(), encoding='utf-8')
        try:
            run(['bash', './gradlew', '--no-daemon', '--console=plain',
                 *(['-Dorg.gradle.java.home=' + str(Path(java_home).resolve())] if java_home else []), '-I', init,
                 '-PdevAppIdSuffix=.mod', '-PmobileVersionName=' + meta['version'],
                 '-PmobileVersionCode=' + str(meta['version_code']), 'assembleRelease'], cwd=android, env=env)
        finally:
            props.unlink(missing_ok=True)
        apks = list((android / 'app/build/outputs/apk/release').glob('*.apk'))
        if len(apks) != 1:
            raise MobileError('expected exactly one release APK')
        unsigned_apk(apks[0])
        badging = run([aapt, 'dump', 'badging', apks[0]], env=env).stdout.decode('utf-8')
        found = re.search(r"package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'", badging)
        if not found or found.groups() != (PACKAGE, str(meta['version_code']), meta['version']):
            raise MobileError('built APK package/version differs from requested release')
        assets = verify_assets(apks[0], dist)
        apk_bytes = apks[0].read_bytes()
        result = {'schema': 1, 'source_commit': meta['source_commit'], 'upstream_commit': meta['source_commit'],
                  'tag': meta['tag'], 'version': meta['version'], 'version_name': meta['version'],
                  'version_code': meta['version_code'], 'package': PACKAGE, 'signed': False,
                  'expected_certificate_sha256': EXPECTED_CERT, 'certificate_sha256': None,
                  'apk': 'mobile-unsigned.apk', 'sha256': sha(apk_bytes), 'bytes': len(apk_bytes),
                  'assets_manifest': assets, 'patch_sha256': meta['patch_sha256']}
        shutil.copyfile(apks[0], stage / 'mobile-unsigned.apk')
        (stage / 'mobile-build.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
        shutil.rmtree(work)
        init.unlink()
        stage.rename(out)
        return result
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def parser():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest='command', required=True)
    prep = commands.add_parser('prepare')
    prep.add_argument('--source', type=Path, required=True)
    prep.add_argument('--tag', required=True)
    prep.add_argument('--commit', required=True)
    prep.add_argument('--version-code', type=int, required=True)
    prep.add_argument('--output', type=Path, required=True)
    compile_cmd = commands.add_parser('build')
    source_group = compile_cmd.add_mutually_exclusive_group(required=True)
    source_group.add_argument('--prepared', type=Path)
    source_group.add_argument('--source', type=Path, help='prepare output directory or its source/ child')
    compile_cmd.add_argument('--output', type=Path, required=True)
    compile_cmd.add_argument('--tag')
    compile_cmd.add_argument('--commit')
    compile_cmd.add_argument('--version-code', type=int)
    return cli


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        if args.command == 'prepare':
            result = prepare(args.source, args.tag, args.commit, args.version_code, args.output)
        else:
            prepared = args.prepared or args.source
            if prepared.name == 'source' and (prepared.parent / 'mobile-prepare.json').is_file():
                prepared = prepared.parent
            result = build(prepared, args.output, tag=args.tag, commit=args.commit,
                           version_code=args.version_code)
        print(json.dumps(result, indent=2))
        return 0
    except (MobileError, OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print('mobile: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
