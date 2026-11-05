"""Offline synthetic tests; optional real same-version integration uses a temp repo.

python -m unittest discover -s test -p test_autoupdate_server.py -v
A2A_TEST_OFFICIAL_ARCHIVE=/cached/official-arm64-3.4.1.tar.gz enables integration.
No network, subprocess payload execution, ADB, or shared-seed writes.
"""
from pathlib import Path
import ast
import hashlib
import gzip
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('autoupdate_server', ROOT / 'scripts/autoupdate/server.py')
server = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(server)

# Auto-sync advances module.prop and seed/VERSION without rewriting tests.
# Derive the next legal metadata transition instead of pinning magisk.37/3.4.1.
SEED_VERSION = re.search(r'^ver=([0-9.]+)$', (ROOT / 'module/seed/VERSION').read_text(encoding='utf-8'), re.M).group(1)
SEED_BUILT = re.search(r'^built=([^\n]+)$', (ROOT / 'module/seed/VERSION').read_text(encoding='utf-8'), re.M).group(1)
PROP_MATCH = re.search(r'^version=v([^ ]+) \(magisk\.([0-9]+)\)$',
                       (ROOT / 'module/module.prop').read_text(encoding='utf-8'), re.M)
NEXT_REVISION = int(PROP_MATCH.group(2)) + 1
import datetime as dt
NEXT_BUILT = (dt.datetime.fromisoformat(SEED_BUILT.replace('Z', '+00:00')) + dt.timedelta(days=1)).isoformat().replace('+00:00', 'Z')
NEXT_VERSION_CODE = int(NEXT_BUILT[:10].replace('-', '')) * 100 + NEXT_REVISION


def file_entry(name, body=b'x', kind=tarfile.REGTYPE, size=None):
    info = tarfile.TarInfo(name)
    info.type = kind
    info.mode = 0o755 if name == 'agent2api-server' else 0o644
    info.size = len(body) if size is None else size
    if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
        info.linkname = 'agent2api-server'
        info.size = 0
    if kind == tarfile.DIRTYPE:
        info.size = 0
    return info, body


BASE = [file_entry('agent2api-server', b'agent2api/3.4.1\0'),
        file_entry('ui/', kind=tarfile.DIRTYPE), file_entry('ui/index.html', b'<html>new</html>')]


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='a2a-archive-test-')
        self.dir = Path(self.tmp.name)
        self.archive = self.dir / 'official.tar'

    def tearDown(self):
        self.tmp.cleanup()

    def archive_of(self, entries):
        with tarfile.open(self.archive, 'w') as tf:
            for info, body in entries:
                tf.addfile(info, io.BytesIO(body) if info.isreg() else None)
        return hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def reject(self, entries, pattern=None):
        sha = self.archive_of(entries)
        with self.assertRaisesRegex(server.ValidationError, pattern or '.'):
            server.read_archive(self.archive, sha)

    def test_valid_known_extras_hashed_and_never_installed(self):
        sha = self.archive_of(BASE + [file_entry('install.sh', b'never execute me'),
                                      file_entry('agent2api.service'), file_entry('agent2api.env.example')])
        payload, members = server.read_archive(self.archive, sha)
        self.assertEqual(set(payload), {'agent2api-server', 'ui/index.html'})
        self.assertEqual(len(members), 6)
        installer = next(m for m in members if m['name'] == 'install.sh')
        self.assertFalse(installer['installed'])
        self.assertEqual(installer['sha256'], server.digest(b'never execute me'))

    def test_symlink(self):
        self.reject(BASE + [file_entry('ui/link', kind=tarfile.SYMTYPE)], 'special')

    def test_hardlink(self):
        self.reject(BASE + [file_entry('ui/link', kind=tarfile.LNKTYPE)], 'special')

    def test_block_device(self):
        self.reject(BASE + [file_entry('ui/dev', kind=tarfile.BLKTYPE)], 'special')

    def test_character_device(self):
        self.reject(BASE + [file_entry('ui/dev', kind=tarfile.CHRTYPE)], 'special')

    def test_fifo(self):
        self.reject(BASE + [file_entry('ui/fifo', kind=tarfile.FIFOTYPE)], 'special')

    def test_traversal(self):
        self.reject(BASE + [file_entry('ui/../../escape')], 'traversal')

    def test_absolute(self):
        self.reject(BASE + [file_entry('/ui/escape')], 'absolute')

    def test_windows_drive(self):
        self.reject(BASE + [file_entry('C:/ui/escape')], 'Windows')

    def test_windows_backslash(self):
        self.reject(BASE + [file_entry('ui\\..\\escape')], 'Windows')

    def test_windows_ads(self):
        self.reject(BASE + [file_entry('ui/index.html:stream')], 'Windows')

    def test_windows_reserved_name(self):
        self.reject(BASE + [file_entry('ui/CON')], 'reserved')

    def test_windows_trailing_dot(self):
        self.reject(BASE + [file_entry('ui/index.html.')], 'noncanonical')

    def test_duplicate(self):
        self.reject(BASE + [file_entry('ui/index.html')], 'duplicate')

    def test_case_collision(self):
        self.reject(BASE + [file_entry('ui/INDEX.html')], 'case-colliding')

    def test_file_directory_prefix_collision(self):
        self.reject(BASE + [file_entry('ui/a'), file_entry('ui/a/b')], 'prefix collision')

    def test_unknown_top_level(self):
        self.reject(BASE + [file_entry('README.md')], 'unknown')

    def test_missing_server(self):
        self.reject(BASE[1:], 'missing top-level server')

    def test_missing_top_level_ui(self):
        self.reject([BASE[0], BASE[2]], 'missing top-level ui')

    def test_missing_index(self):
        self.reject(BASE[:2], 'index')

    def test_empty_server(self):
        self.reject([file_entry('agent2api-server', b''), *BASE[1:]], 'empty server')

    def test_member_size_bound(self):
        with patch.object(server, 'MAX_MEMBER', 2):
            self.reject(BASE, 'member size')

    def test_total_size_bound(self):
        with patch.object(server, 'MAX_TOTAL', 20):
            self.reject(BASE, 'expanded size')

    def test_member_count_bound(self):
        with patch.object(server, 'MAX_MEMBERS', 2):
            self.reject(BASE, 'member count')

    def test_archive_size_bound(self):
        sha = self.archive_of(BASE)
        with patch.object(server, 'MAX_ARCHIVE', 16):
            with self.assertRaisesRegex(server.ValidationError, 'archive size'):
                server.read_archive(self.archive, sha)

    def test_hash_mismatch(self):
        self.archive_of(BASE)
        with self.assertRaisesRegex(server.ValidationError, 'sha256 mismatch'):
            server.read_archive(self.archive, '0' * 64)

    def test_hash_format(self):
        for value in ('x' * 64, 'abc', '0' * 63, '0' * 65):
            with self.subTest(value=value):
                with self.assertRaisesRegex(server.ValidationError, '64 hex'):
                    server.read_archive(self.archive, value)

    def test_sparse_metadata(self):
        entry = file_entry('ui/sparse')
        entry[0].pax_headers = {'GNU.sparse.name': 'ui/sparse'}
        self.reject(BASE + [entry])

    def test_hidden_trailing_stream(self):
        self.archive_of(BASE)
        self.archive.write_bytes(self.archive.read_bytes() + b'evil'.ljust(512, b'\0'))
        with self.assertRaisesRegex(server.ValidationError, 'trailer'):
            server.read_archive(self.archive, server.digest(self.archive.read_bytes()))

    def test_gzip_expansion_limit_before_tar_metadata(self):
        self.archive.write_bytes(gzip.compress(b'0' * 20000))
        with patch.object(server, 'MAX_TAR_STREAM', 1000):
            with self.assertRaisesRegex(server.ValidationError, 'tar stream size'):
                server.read_archive(self.archive, server.digest(self.archive.read_bytes()))

    def test_malformed_tar(self):
        self.archive.write_bytes(b'not a tar')
        with self.assertRaisesRegex(server.ValidationError, 'invalid/truncated'):
            server.read_archive(self.archive, server.digest(self.archive.read_bytes()))

    def test_pack_failure_leaves_source_untouched(self):
        repo = self.dir / 'repo'
        shutil.copytree(ROOT / 'module', repo / 'module')
        shutil.copyfile(ROOT / 'pack.py', repo / 'pack.py')
        before = server.regular_tree(repo / 'module')
        sha = self.archive_of(BASE)
        with patch.object(server, 'elf_report', return_value={'status': 'PASS'}), \
                patch.object(server, 'pack_twice', side_effect=server.ValidationError('synthetic pack failure')):
            with self.assertRaisesRegex(server.ValidationError, 'pack failure'):
                server.sync(self.archive, sha, SEED_VERSION, NEXT_BUILT, NEXT_REVISION, self.dir / 'out', repo,
                            commit='b' * 40)
        self.assertEqual(before, server.regular_tree(repo / 'module'))
        self.assertFalse((self.dir / 'out').exists())

    def test_bad_elf_rejected_before_source_write(self):
        repo = self.dir / 'repo'
        shutil.copytree(ROOT / 'module', repo / 'module')
        shutil.copyfile(ROOT / 'pack.py', repo / 'pack.py')
        before = server.regular_tree(repo / 'module')
        sha = self.archive_of(BASE)
        with self.assertRaises(Exception):
            server.sync(self.archive, sha, SEED_VERSION, NEXT_BUILT, NEXT_REVISION, self.dir / 'out', repo,
                        commit='b' * 40)
        self.assertEqual(before, server.regular_tree(repo / 'module'))
        self.assertFalse((self.dir / 'out').exists())


class MetadataAndElfTests(unittest.TestCase):
    def test_generalized_r18_function(self):
        tree = ast.parse((ROOT / 'test/verify_fixes.py').read_text(encoding='utf-8'))
        fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'r18_metadata_consistent')
        scope = {}
        exec(compile(ast.Module(body=[fn], type_ignores=[]), '<r18-function>', 'exec'), scope)
        check = scope['r18_metadata_consistent']
        for version in ('3.4.1', '4.0.0', '10.22.333'):
            output = ('METRIC binary={v}\nMETRIC version_file={v}\nMETRIC consistent=1\n'
                      'METRIC module_prop=v{v} (magisk.42)\nMETRIC prop_mentions_payload=1\n').format(v=version)
            self.assertTrue(check(output))
            self.assertFalse(check(output.replace('version_file=' + version, 'version_file=0.0.0')))
            self.assertFalse(check(output.replace('consistent=1', 'consistent=0')))
        self.assertFalse(check('METRIC binary=\n'))

    def test_metadata_valid_and_monotonic(self):
        prop, version, name = server.metadata(ROOT / 'module', SEED_VERSION, NEXT_BUILT, NEXT_REVISION, 'a' * 64,
                                               'b' * 40)
        self.assertIn(f'versionCode={NEXT_VERSION_CODE}'.encode(), prop)
        self.assertIn(b'archive_sha256=' + b'a' * 64, version)
        self.assertIn(b'commit=' + b'b' * 40, version)
        self.assertIn(b'updateJson=https://raw.githubusercontent.com/84593320z/agent2api-magisk/main/update.json', prop)
        self.assertEqual(name, f'v{SEED_VERSION} (magisk.{NEXT_REVISION})')

    def test_metadata_preserves_repo_tracked_text(self):
        """Only generated fields change: description body, VERSION comments and key order survive."""
        source = (ROOT / 'module/module.prop').read_text(encoding='utf-8')
        body = source.split('description=', 1)[1].split('\n', 1)[0].split('｜', 1)[1]
        seed_lines = (ROOT / 'module/seed/VERSION').read_text(encoding='utf-8').splitlines()
        comments = [n for n in seed_lines if n.startswith('#')]
        prop, version, _ = server.metadata(ROOT / 'module', SEED_VERSION, NEXT_BUILT, NEXT_REVISION, 'c' * 64,
                                           'd' * 40)
        text, seed = prop.decode('utf-8'), version.decode('utf-8')
        self.assertIn(body, text)
        self.assertIn(f'模块 v{SEED_VERSION} magisk.{NEXT_REVISION}｜', text)
        self.assertEqual([n for n in seed.splitlines() if n.startswith('#')], comments)
        self.assertEqual([n.split('=', 1)[0] for n in seed.splitlines() if '=' in n and not n.startswith('#')],
                         [n.split('=', 1)[0] for n in seed_lines if '=' in n and not n.startswith('#')])
        self.assertIn('commit=%s' % ('d' * 40), seed)
        self.assertEqual([n for n in seed.splitlines() if n.startswith('commit=')],
                         ['commit=' + 'd' * 40])

    def test_metadata_rolls_payload_version_but_keeps_release_notes(self):
        """A future version must update '载荷 vX.Y.Z' (r18 greps it) without losing hand-written notes."""
        old = (ROOT / 'module/module.prop').read_text(encoding='utf-8')
        body = old.split('description=', 1)[1].split('\n', 1)[0].split('｜', 1)[1]
        future = SEED_VERSION.rsplit('.', 1)[0] + '.' + str(int(SEED_VERSION.rsplit('.', 1)[1]) + 1)
        notes = re.sub(r'载荷 v[0-9]+(?:\.[0-9]+)*', '载荷 v' + future, body)
        prop, _, name = server.metadata(ROOT / 'module', future, NEXT_BUILT, NEXT_REVISION, 'a' * 64, 'b' * 40)
        text = prop.decode('utf-8')
        line = text.split('description=', 1)[1].split('\n', 1)[0]
        self.assertEqual(line, f'模块 v{future} magisk.{NEXT_REVISION}｜' + notes)
        self.assertEqual(text.count('载荷 v' + future), 1)
        self.assertNotIn('载荷 v' + SEED_VERSION, text)
        self.assertEqual(name, f'v{future} (magisk.{NEXT_REVISION})')

    def test_metadata_rejects_injection_rollback_and_nonmonotonic(self):
        cases = [('v3.4.1', '2026-11-04T09:17:30Z', 38),
                 ('3.4.1\nkey=x', '2026-11-04T09:17:30Z', 38),
                 ('3.4.0', '2026-11-04T09:17:30Z', 38),
                 ('3.4.1', '2026-11-04T09:17:30Z', 37),
                 ('3.4.1', '2026-11-03T09:17:30Z', 38),
                 ('3.4.1', '2026-11-04', 38),
                 ('3.4.1', '2026-99-04T09:17:30Z', 38),
                 ('3.4.1', '2026-11-04T09:17:30Z', 100)]
        for version, built, revision in cases:
            with self.subTest(version=version, built=built, revision=revision):
                with self.assertRaises(server.ValidationError):
                    server.metadata(ROOT / 'module', version, built, revision, 'a' * 64, 'b' * 40)

    def test_metadata_rejects_bad_commit(self):
        for bad in ('', '3FF4B82', 'z' * 40, 'a' * 39, 'a' * 41):
            with self.subTest(commit=bad):
                with self.assertRaisesRegex(server.ValidationError, 'commit'):
                    server.metadata(ROOT / 'module', '3.4.1', '2026-11-04T09:17:30Z', 38, 'a' * 64, bad)

    def test_real_seed_elf_closure(self):
        report = server.elf_report(ROOT / 'module/seed/agent2api-server', ROOT / 'module/seed/lib', SEED_VERSION)
        self.assertEqual(report['status'], 'PASS')
        self.assertTrue(report['all_strong_imports_resolved'])
        self.assertEqual(len(report['files']), 11)

    def test_binary_string_must_match_exactly(self):
        with self.assertRaisesRegex(server.ValidationError, 'version strings'):
            server.elf_report(ROOT / 'module/seed/agent2api-server', ROOT / 'module/seed/lib', '0.0.0')

    def test_unversioned_strong_symbol_is_checked(self):
        original = server.inspect_elf
        def missing_symbol(path):
            info = original(path)
            if path.name == 'agent2api-server':
                info['imports'].append(['synthetic_unresolved_strong_symbol', None])
            return info
        with patch.object(server, 'inspect_elf', side_effect=missing_symbol):
            with self.assertRaisesRegex(server.ValidationError, 'missing strong symbol'):
                server.elf_report(ROOT / 'module/seed/agent2api-server', ROOT / 'module/seed/lib', SEED_VERSION)

    def test_missing_dependency_and_gnu_version_rejected(self):
        original = server.inspect_elf
        for fault in ('dependency', 'version'):
            def broken(path):
                info = original(path)
                if path.name == 'agent2api-server':
                    if fault == 'dependency':
                        info['needed'].append('lib-synthetic-missing.so')
                    else:
                        info['required_versions']['libc.so.6'].append('GLIBC_SYNTHETIC_MISSING')
                return info
            with self.subTest(fault=fault), patch.object(server, 'inspect_elf', side_effect=broken):
                with self.assertRaisesRegex(server.ValidationError, 'ELF closure failure'):
                    server.elf_report(ROOT / 'module/seed/agent2api-server', ROOT / 'module/seed/lib', SEED_VERSION)

    def test_bad_interpreter_rejected(self):
        original = server.inspect_elf
        def bad_interpreter(path):
            info = original(path)
            if path.name == 'agent2api-server':
                info['interpreter'] = ['/system/bin/linker64']
            return info
        with patch.object(server, 'inspect_elf', side_effect=bad_interpreter):
            with self.assertRaisesRegex(server.ValidationError, 'interpreter'):
                server.elf_report(ROOT / 'module/seed/agent2api-server', ROOT / 'module/seed/lib', SEED_VERSION)


@unittest.skipUnless(os.environ.get('A2A_TEST_OFFICIAL_ARCHIVE'), 'set A2A_TEST_OFFICIAL_ARCHIVE to cached official tar')
class OfficialIntegration(unittest.TestCase):
    def test_same_341_in_isolated_repo(self):
        archive = Path(os.environ['A2A_TEST_OFFICIAL_ARCHIVE']).resolve()
        source_before = server.regular_tree(ROOT / 'module')
        with tempfile.TemporaryDirectory(prefix='a2a-official-integration-') as tmp:
            root = Path(tmp)
            repo = root / 'repo'
            shutil.copytree(ROOT / 'module', repo / 'module')
            shutil.copyfile(ROOT / 'pack.py', repo / 'pack.py')
            (repo / 'module/seed/ui/stale-autoupdate-test.js').write_bytes(b'old')
            cli = repo / 'scripts/autoupdate/server.py'
            cli.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'scripts/autoupdate/server.py', cli)
            process = subprocess.run([sys.executable, str(cli), '--archive', str(archive),
                                      '--sha256', 'd494e333a697ca9b48f17fc84cd10abdbe5f113a2900aba372fdac3503971e1c',
                                      '--version', '3.4.1', '--built', '2026-11-04T09:17:30Z',
                                      '--module-revision', '38',
                                      '--commit', '3ff4b8215d0d65c3451ca74923e90964ed7dbf59',
                                      '--output', str(root / 'evidence')],
                                     capture_output=True, text=True, encoding='utf-8', timeout=120)
            self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
            result = json.loads(process.stdout)
            print('CLI_INTEGRATION ' + json.dumps(result, ensure_ascii=False))
            self.assertEqual(result['status'], 'PASS')
            manifest = json.loads((root / 'evidence/provenance.json').read_text(encoding='utf-8'))
            report = json.loads((root / 'evidence/elf-compatibility.json').read_text(encoding='utf-8'))
            self.assertTrue(manifest['zip']['two_runs_identical'])
            self.assertFalse((repo / 'module/seed/ui/stale-autoupdate-test.js').exists())
            self.assertEqual(manifest['stable_seed_libraries'],
                             {n: h for n, h in source_before.items() if n.startswith('seed/lib/')})
            self.assertEqual(report['status'], 'PASS')
            self.assertTrue(Path(result['zip']).is_file())
            after = server.regular_tree(repo / 'module')
            mutable = lambda n: n in ('module.prop', 'seed/VERSION', 'seed/agent2api-server') or n.startswith('seed/ui/')
            self.assertEqual({n: h for n, h in source_before.items() if not mutable(n)},
                             {n: h for n, h in after.items() if not mutable(n)})
        self.assertEqual(source_before, server.regular_tree(ROOT / 'module'))


if __name__ == '__main__':
    unittest.main()
