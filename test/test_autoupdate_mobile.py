"""Offline regression tests: real Git merges and ZIP bytes; no network/SDK/ADB."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('autoupdate_mobile', ROOT / 'scripts/autoupdate/mobile.py')
mobile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mobile)


def command(*args, cwd=None):
    return subprocess.check_output([str(a) for a in args], cwd=cwd, stderr=subprocess.PIPE)


class MobileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mobile-test-')
        self.base = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def put(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8', newline='\n')

    def fixture(self):
        source = self.base / 'upstream'
        source.mkdir()
        command('git', 'init', source)
        command('git', '-C', source, 'config', 'user.name', 'Offline Test')
        command('git', '-C', source, 'config', 'user.email', 'offline@example.invalid')
        command('git', '-C', source, 'config', 'core.autocrlf', 'false')
        command('git', '-C', source, 'config', 'core.hooksPath', '')
        for rel in ('App.tsx', 'pages/ServersPage.tsx', 'pages/SettingsPage.tsx', 'state/store.ts'):
            self.put(source / mobile.SRC / rel, 'original\n' + ''.join(f'line {i}\n' for i in range(25)))
        self.put(source / mobile.MOBILE / 'android/app/build.gradle', '// offline fixture\n')
        self.put(source / mobile.MOBILE / 'package.json', '{"version":"1.2.3"}')
        self.put(source / mobile.MOBILE / 'package-lock.json', '{"version":"1.2.3","packages":{"":{"version":"1.2.3"}}}')
        command('git', '-C', source, 'add', '.')
        command('git', '-C', source, 'commit', '-m', 'base')
        base_commit = command('git', '-C', source, 'rev-parse', 'HEAD').decode().strip()
        self.put(source / mobile.SRC / 'App.tsx', 'overlay\n' + ''.join(f'line {i}\n' for i in range(25)))
        # Use the exact currently shipped concurrency/echo safeguards, not fake tokens.
        for rel in ('api/switches.ts', 'components/GatewaySwitches.tsx', 'lib/discover.ts'):
            path = source / mobile.SRC / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes((ROOT / 'apk-mod/src' / rel).read_bytes())
        command('git', '-C', source, 'add', '.')
        patch_bytes = command('git', '-C', source, 'diff', '--cached', '--binary', '--full-index')
        repo = self.base / 'overlay-repo'
        self.put(repo / 'apk-mod/a2a-mobile-mod.patch', patch_bytes.decode())
        for rel in mobile.SNAPSHOTS:
            dest = repo / 'apk-mod/src' / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((source / mobile.SRC / rel).read_bytes())
        command('git', '-C', source, 'reset', '--hard', base_commit)
        command('git', '-C', source, 'clean', '-fd')
        command('git', '-C', source, 'tag', 'v1.2.3')
        return source, repo, base_commit

    def prepared(self):
        source, repo, commit = self.fixture()
        output = self.base / 'prepared'
        meta = mobile.prepare(source, 'v1.2.3', commit, 123456, output, repo)
        return source, repo, output, meta

    def test_version_and_parameterized_cli(self):
        self.assertEqual(mobile.version('v12.34.56', 987654), '12.34.56')
        for tag in ('1.2.3', 'v1.2', 'v01.2.3', 'v1.2.3;echo hi', 'v1.2.3-beta'):
            with self.assertRaises(mobile.MobileError):
                mobile.version(tag, 123)
        for code in (0, -1, True, 2100000001, '12'):
            with self.assertRaises(mobile.MobileError):
                mobile.version('v1.2.3', code)
        args = mobile.parser().parse_args(['prepare', '--source', 'clone', '--tag', 'v12.34.56',
                    '--commit', 'a' * 40, '--version-code', '987654', '--output', 'out'])
        self.assertEqual(args.version_code, 987654)
        self.assertEqual(args.tag, 'v12.34.56')
        self.assertIn('mobileVersionCode', mobile.gradle_init())
        self.assertIn('signingConfig = null', mobile.gradle_init())
        self.assertNotIn('storePassword', mobile.gradle_init())

    def test_prepare_refreshes_seven_and_regenerates_patch(self):
        source, repo, output, meta = self.prepared()
        self.assertEqual(set(meta['snapshots']), set(mobile.SNAPSHOTS))
        self.assertEqual(meta['version_code'], 123456)
        self.assertEqual(command('git', '-C', source, 'status', '--porcelain'), b'')
        for rel in mobile.SNAPSHOTS:
            self.assertEqual((repo / 'apk-mod/src' / rel).read_bytes(),
                             (output / 'source' / mobile.SRC / rel).read_bytes())
        self.assertEqual((repo / 'apk-mod/a2a-mobile-mod.patch').read_bytes(),
                         (output / 'a2a-mobile-mod.patch').read_bytes())
        work = output / 'source'
        command('git', '-C', work, 'reset', '--hard', meta['source_commit'])
        command('git', '-C', work, 'apply', '--check', output / 'a2a-mobile-mod.patch')
        self.assertFalse(any(self.base.glob('.mobile-prepare-*')))

    def test_upstream_addition_survives_without_snapshot_overwrite(self):
        source, repo, _ = self.fixture()
        app = source / mobile.SRC / 'App.tsx'
        app.write_text(app.read_text() + 'new upstream feature\n', newline='\n')
        command('git', '-C', source, 'add', '.')
        command('git', '-C', source, 'commit', '-m', 'next version')
        command('git', '-C', source, 'tag', 'v1.2.4')
        commit = command('git', '-C', source, 'rev-parse', 'HEAD').decode().strip()
        meta = mobile.prepare(source, 'v1.2.4', commit, 124, self.base / 'next', repo)
        self.assertEqual(meta['version'], '1.2.4')
        self.assertIn('new upstream feature', (repo / 'apk-mod/src/App.tsx').read_text())
        self.assertTrue((repo / 'apk-mod/src/App.tsx').read_text().startswith('overlay\n'))

    def test_three_way_fallback_preserves_upstream_nonoverlap(self):
        source, repo, _ = self.fixture()
        app = source / mobile.SRC / 'App.tsx'
        text = app.read_text().replace('line 1\n', 'nearby upstream change\n')
        app.write_text(text, newline='\n')
        command('git', '-C', source, 'add', '.')
        command('git', '-C', source, 'commit', '-m', 'context changed')
        command('git', '-C', source, 'tag', 'v1.2.4')
        commit = command('git', '-C', source, 'rev-parse', 'HEAD').decode().strip()
        mobile.prepare(source, 'v1.2.4', commit, 124, self.base / 'merged', repo)
        result = (repo / 'apk-mod/src/App.tsx').read_text()
        self.assertIn('nearby upstream change', result)
        self.assertTrue(result.startswith('overlay\n'))

    def test_patch_conflict_fails_without_publication(self):
        source, repo, _ = self.fixture()
        self.put(source / mobile.SRC / 'App.tsx', 'upstream conflict\n')
        command('git', '-C', source, 'add', '.')
        command('git', '-C', source, 'commit', '-m', 'conflicting upstream')
        command('git', '-C', source, 'tag', 'v1.2.4')
        commit = command('git', '-C', source, 'rev-parse', 'HEAD').decode().strip()
        before = {str(p): p.read_bytes() for p in repo.rglob('*') if p.is_file()}
        out = self.base / 'conflicted-output'
        with self.assertRaises(mobile.MobileError):
            mobile.prepare(source, 'v1.2.4', commit, 124, out, repo)
        self.assertFalse(out.exists())
        self.assertEqual(before, {str(p): p.read_bytes() for p in repo.rglob('*') if p.is_file()})
        self.assertFalse(list(self.base.glob('.mobile-prepare-*')))

    def test_tag_commit_mismatch_and_abbreviated_commit(self):
        source, repo, commit = self.fixture()
        for bad in ('0' * 40, commit[:12]):
            with self.assertRaises(mobile.MobileError):
                mobile.prepare(source, 'v1.2.3', bad, 123, self.base / 'bad', repo)
        self.assertFalse((self.base / 'bad').exists())

    def test_paths_and_patch_path_confinement(self):
        protected = self.base / 'protected'
        protected.mkdir()
        for out in (protected, protected / 'child', self.base):
            with self.assertRaises(mobile.MobileError):
                mobile.output_path(out, protected)
        existing = self.base / 'existing'
        existing.mkdir()
        with self.assertRaises(mobile.MobileError):
            mobile.output_path(existing)
        for target in ('../../escape', 'desktop-tauri/mobile/src/Other.tsx', '/absolute'):
            data = f'diff --git a/{target} b/{target}\n'.encode()
            with self.assertRaises(mobile.MobileError):
                mobile.validate_patch(data)

    def make_apk(self, count=7, mismatch=False, extra=False, signed=False):
        dist = self.base / 'dist'
        for rel in ['index.html', 'mobile.js', 'mobile.css'] + [f'assets/icon-{i}.svg' for i in range(count)]:
            self.put(dist / rel, rel + ' fresh bytes')
        apk = self.base / 'unsigned.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            for p in dist.rglob('*'):
                if p.is_file():
                    data = b'stale' if mismatch and p.name == 'mobile.js' else p.read_bytes()
                    archive.writestr('assets/public/' + p.relative_to(dist).as_posix(), data)
            archive.writestr('assets/public/cordova.js', b'')
            archive.writestr('assets/public/cordova_plugins.js', b'')
            archive.writestr('assets/capacitor.plugins.json', json.dumps([{'pkg': '@capacitor/app'}, {'pkg': '@capacitor/keyboard'}]))
            archive.writestr('resources.arsc', b'resources', compress_type=zipfile.ZIP_STORED)
            if extra:
                archive.writestr('assets/public/old.js', b'stale')
            if signed:
                archive.writestr('META-INF/CERT.RSA', b'certificate')
        return apk, dist

    def test_zip_compares_real_dist_not_hardcoded_178(self):
        apk, dist = self.make_apk(count=183)
        report = mobile.verify_assets(apk, dist)
        self.assertEqual(report['asset_count'], 186)
        self.assertTrue(report['all_web_assets_match'])
        mobile.unsigned_apk(apk)

    def test_stale_or_extra_web_assets_fail(self):
        for kwargs in ({'mismatch': True}, {'extra': True}):
            apk, dist = self.make_apk(**kwargs)
            with self.assertRaises(mobile.MobileError):
                mobile.verify_assets(apk, dist)

    def test_signed_apk_rejected(self):
        apk, _ = self.make_apk(signed=True)
        with self.assertRaises(mobile.MobileError):
            mobile.unsigned_apk(apk)

    def test_v2_signing_block_rejected(self):
        import struct
        apk, _ = self.make_apk()
        data = bytearray(apk.read_bytes())
        eocd = data.rfind(b'PK\x05\x06')
        central = struct.unpack_from('<I', data, eocd + 16)[0]
        block = struct.pack('<Q', 24) + struct.pack('<Q', 24) + b'APK Sig Block 42'
        data[central:central] = block
        struct.pack_into('<I', data, eocd + len(block) + 16, central + len(block))
        apk.write_bytes(data)
        with self.assertRaisesRegex(mobile.MobileError, 'signing block'):
            mobile.unsigned_apk(apk)

    def test_promisor_clone_rejected(self):
        source, repo, commit = self.fixture()
        command('git', '-C', source, 'config', 'remote.origin.promisor', 'true')
        with self.assertRaisesRegex(mobile.MobileError, 'partial clones'):
            mobile.prepare(source, 'v1.2.3', commit, 123, self.base / 'partial', repo)
        self.assertFalse((self.base / 'partial').exists())

    def test_build_parameter_mismatch_fails_before_tools(self):
        _, _, output, _ = self.prepared()
        with patch.object(mobile.sys, 'platform', 'linux'):
            with self.assertRaisesRegex(mobile.MobileError, 'parameters differ'):
                mobile.build(output, self.base / 'build', version_code=99)
        self.assertFalse((self.base / 'build').exists())

    @unittest.skipUnless(os.environ.get('AUTOUPDATE_MOBILE_TEST_UPSTREAM'), 'set AUTOUPDATE_MOBILE_TEST_UPSTREAM for real local upstream integration')
    def test_real_local_upstream_prepare(self):
        source = Path(os.environ['AUTOUPDATE_MOBILE_TEST_UPSTREAM']).resolve()
        repo = self.base / 'real-overlay'
        for rel in ['a2a-mobile-mod.patch'] + ['src/' + p for p in mobile.SNAPSHOTS]:
            dest = repo / 'apk-mod' / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes((ROOT / 'apk-mod' / rel).read_bytes())
        commit = command('git', '-C', source, 'rev-parse', 'refs/tags/v3.4.1^{commit}').decode().strip()
        promisor = subprocess.run(['git', '-C', str(source), 'config', '--get-regexp', r'^remote\..*\.promisor$'], stdout=subprocess.PIPE)
        if promisor.returncode == 0:
            with self.assertRaisesRegex(mobile.MobileError, 'partial clones'):
                mobile.prepare(source, 'v3.4.1', commit, 30401, self.base / 'real-output', repo)
            return
        result = mobile.prepare(source, 'v3.4.1', commit, 30401, self.base / 'real-output', repo)
        self.assertEqual(result['source_commit'], commit)
        self.assertEqual(len(result['snapshots']), 7)
        app = (repo / 'apk-mod/src/App.tsx').read_text(encoding='utf-8')
        self.assertIn('ToolsPage', app)
        work = self.base / 'real-output/source'
        for rel in ('pages/ToolsPage.tsx', 'lib/assistantTools.ts', 'state/store.ts'):
            upstream = command('git', '-C', work, 'show', 'HEAD:' + mobile.SRC + rel)
            self.assertEqual((work / mobile.SRC / rel).read_bytes(), upstream)
        mobile.validate_switches(work)

    def test_build_linux_unsigned_commands_and_manifest(self):
        _, _, output, meta = self.prepared()
        sdk = self.base / 'sdk'
        self.put(sdk / 'platforms/android-36/android.jar', '')
        self.put(sdk / 'build-tools/36.0.0/aapt2', '')
        commands = []
        real_run = mobile.run

        def fake_run(args, cwd=None, env=None, check=True):
            args = [str(a) for a in args]
            commands.append((args, cwd))
            if args[0] == 'git':
                return real_run(args, cwd, env, check)
            self.assertNotIn('A2A_KEYSTORE', env)
            if Path(args[0]).name in ('java', 'java.exe') and args[1:] == ['-version']:
                return subprocess.CompletedProcess(args, 0, b'', b'openjdk version "21.0.1"')
            if args[:3] == ['npm', 'run', 'build:native']:
                for name in ('index.html', 'mobile.js', 'mobile.css'):
                    self.put(Path(cwd) / 'android-www' / name, name)
            if args[0] == 'bash':
                self.assertTrue((Path(cwd) / 'keystore.properties').is_file())
                self.assertNotIn('storePassword', (Path(cwd) / 'keystore.properties').read_text())
                dest = Path(cwd) / 'app/build/outputs/apk/release/app-release-unsigned.apk'
                dest.parent.mkdir(parents=True)
                with zipfile.ZipFile(dest, 'w') as archive:
                    for p in (Path(cwd).parent / 'android-www').iterdir():
                        archive.writestr('assets/public/' + p.name, p.read_bytes())
                    archive.writestr('assets/capacitor.plugins.json', json.dumps([{'pkg': '@capacitor/app'}, {'pkg': '@capacitor/keyboard'}]))
                    archive.writestr('resources.arsc', b'')
            if args[0].endswith('aapt2'):
                return subprocess.CompletedProcess(args, 0, b"package: name='com.agent2api.mobile.mod' versionCode='123456' versionName='1.2.3'", b'')
            return subprocess.CompletedProcess(args, 0, b'', b'')

        with patch.object(mobile.sys, 'platform', 'linux'), patch.object(mobile, 'run', fake_run), \
             patch.dict(os.environ, {'ANDROID_SDK_ROOT': str(sdk), 'A2A_KEYSTORE': 'never-read'}):
            result = mobile.build(output, self.base / 'built')
        gradle = next(args for args, _ in commands if args[0] == 'bash')
        self.assertIn('-PdevAppIdSuffix=.mod', gradle)
        self.assertIn('-PmobileVersionCode=123456', gradle)
        self.assertIn('-PmobileVersionName=1.2.3', gradle)
        self.assertEqual(sum(args[:2] == ['npm', 'ci'] for args, _ in commands), 2)
        self.assertFalse(result['signed'])
        self.assertEqual(result['source_commit'], meta['source_commit'])
        self.assertEqual(result['expected_certificate_sha256'], mobile.EXPECTED_CERT)
        self.assertEqual(result['assets_manifest']['asset_count'], 3)
        self.assertEqual({p.name for p in (self.base / 'built').iterdir()}, {'mobile-build.json', 'mobile-unsigned.apk'})
        self.assertFalse(list(self.base.glob('.mobile-build-*')))


if __name__ == '__main__':
    unittest.main()
