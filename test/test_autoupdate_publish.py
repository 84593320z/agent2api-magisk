import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/autoupdate'))
import publish


class ReleaseReplacementTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.old = self.root / 'old.bin'
        self.new = self.root / 'new.bin'
        self.same = self.root / 'same.bin'
        self.old.write_bytes(b'old')
        self.new.write_bytes(b'new')
        self.same.write_bytes(b'same')
        self.release = {
            'id': 7, 'tag_name': 'apk-v1-mod', 'draft': False,
            'html_url': 'https://example.invalid/release',
            'upload_url': 'https://example.invalid/upload{?name,label}',
            'assets': [
                {'id': 1, 'name': 'new.bin', 'size': 3, 'url': 'old'},
                {'id': 2, 'name': 'same.bin', 'size': 4, 'url': 'same'},
            ],
        }
        self.bodies = {1: b'old', 2: b'same'}
        self.calls = []

    def api(self, path, method='GET', data=None):
        self.calls.append((path, method, data))
        if path == '/git/matching-refs/tags/apk-v1-mod':
            return [{'ref': 'refs/tags/apk-v1-mod',
                     'object': {'type': 'commit', 'sha': 'a' * 40}}]
        if path == '/releases?per_page=100':
            return [self.release]
        if method == 'PATCH' and path == '/releases/7':
            return dict(self.release)
        return {}

    def upload(self, release, path, data):
        asset = {'id': 99, 'name': path.name, 'size': len(data), 'url': 'new'}
        self.bodies[99] = data
        return asset

    def run_release(self, commit=None, **kwargs):
        with patch.object(publish, 'api', side_effect=self.api), \
             patch.object(publish, 'download_asset', side_effect=lambda asset: self.bodies[asset['id']]), \
             patch.object(publish, 'upload_asset', side_effect=self.upload):
            return publish.release('apk-v1-mod', commit or 'b' * 40, [self.new, self.same],
                                   'body', **kwargs)

    def test_normal_release_never_replaces_or_moves(self):
        with self.assertRaisesRegex(ValueError, 'hash differs'):
            self.run_release(commit='a' * 40)
        self.assertFalse(any(method == 'DELETE' for _, method, _ in self.calls))
        self.assertFalse(any(method == 'PATCH' for _, method, _ in self.calls))

    def test_republish_replaces_only_changed_assets_then_moves_tag(self):
        self.run_release(move_tag=True, replace_assets=True)
        self.assertIn(('/releases/assets/1', 'DELETE', None), self.calls)
        self.assertFalse(any(path == '/releases/assets/2' and method == 'DELETE'
                             for path, method, _ in self.calls))
        self.assertIn(('/git/refs/tags/apk-v1-mod', 'PATCH',
                       {'sha': 'b' * 40, 'force': True}), self.calls)
        self.assertTrue(any(path == '/releases/7' and method == 'PATCH'
                            for path, method, _ in self.calls))

    def test_move_requires_replacement_mode(self):
        with self.assertRaisesRegex(ValueError, 'replacement'):
            self.run_release(move_tag=True)

    def test_track_identity_uses_actual_assets_and_rejects_unexpected_extras(self):
        self.new.write_bytes(b'old')
        with patch.object(publish, 'get_release', return_value=self.release), \
             patch.object(publish, 'download_asset', side_effect=lambda asset: self.bodies[asset['id']]):
            self.assertTrue(publish.release_assets_identical('apk-v1-mod', [self.new, self.same]))
            self.new.write_bytes(b'changed')
            self.assertFalse(publish.release_assets_identical('apk-v1-mod', [self.new, self.same]))
            self.release['assets'].append({'id': 3, 'name': 'unexpected', 'size': 0})
            with self.assertRaisesRegex(ValueError, 'Unexpected existing assets'):
                publish.release_assets_identical('apk-v1-mod', [self.new, self.same])

    def test_missing_track_is_a_controlled_creation_not_an_identity_match(self):
        with patch.object(publish, 'get_release', return_value=None):
            self.assertFalse(publish.release_assets_identical('apk-v1-mod', [self.new, self.same]))


class PublishOrderingTests(unittest.TestCase):
    def fixture(self, mobile=False):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        root = Path(temp.name)
        artifacts = root / 'artifacts'
        artifacts.mkdir()
        (root / 'scripts/autoupdate').mkdir(parents=True)
        config = {
            'repository': '84593320z/agent2api-magisk', 'certificate_sha256': 'cert',
            'last_version': '3.5.0-beta.1', 'last_commit': 'b' * 40,
            'module_revision': 41, 'mobile_version_code': 30500,
        }
        (root / 'scripts/autoupdate/config.json').write_text(json.dumps(config), encoding='utf-8')
        plan = {
            'changed': True, 'republish': True, 'tag': 'v3.5.0-beta.1',
            'version': '3.5.0-beta.1', 'commit': 'b' * 40,
            'module_revision': 42, 'mobile_version_code': 30500, 'prerelease': True,
        }
        plan_path = artifacts / 'plan.json'
        plan_path.write_text(json.dumps(plan), encoding='utf-8')
        apk = artifacts / 'Agent2API-3.5.0-beta.1-mod.apk'
        apk.write_bytes(b'apk')
        module = artifacts / 'agent2api-magisk-v3.5.0-beta.1-magisk.42-arm64.zip'
        module.write_bytes(b'x' * 1000001)
        (artifacts / 'signature.json').write_text(json.dumps({
            'certificate_sha256': 'cert', 'version': plan['version'],
            'sha256': hashlib.sha256(apk.read_bytes()).hexdigest(),
        }), encoding='utf-8')
        for name in ('provenance.json', 'mobile-build.json'):
            (artifacts / name).write_text('{}', encoding='utf-8')
        (artifacts / 'elf-compatibility.json').write_text('{"status":"PASS"}', encoding='utf-8')
        (artifacts / 'full-regression.txt').write_text('=== 全部通过 ===\n', encoding='utf-8')
        paths = ['module/module.prop', 'scripts/autoupdate/config.json']
        if mobile:
            paths.append('apk-mod/src/lib/discover.ts')
        with zipfile.ZipFile(artifacts / 'candidate.zip', 'w') as z:
            z.writestr('manifest.json', json.dumps([{'path': path} for path in paths]))
        return root, SimpleNamespace(plan=plan_path, artifacts=artifacts, expected='a' * 40)

    def run_publish(self, track_changed):
        root, args = self.fixture(False)
        events = []
        with patch.object(publish, 'ROOT', root), \
             patch.object(publish, 'commit_candidate', side_effect=lambda *a: events.append('commit') or 'c' * 40), \
             patch.object(publish, 'release_assets_identical', side_effect=lambda *a: events.append('apk-compare') or not track_changed), \
             patch.object(publish, 'release', side_effect=lambda *a, **kw: events.append(('release', a[0], kw))), \
             patch.object(publish, 'commit_docs', side_effect=lambda *a: events.append('docs')):
            publish.publish(args)
        return events

    def test_identical_apk_track_is_compared_before_checkpoint_and_docs_are_last(self):
        events = self.run_publish(False)
        self.assertEqual(events[0:2], ['apk-compare', 'commit'])
        self.assertEqual(events[-1], 'docs')
        releases = [event for event in events if isinstance(event, tuple)]
        self.assertEqual(len(releases), 2)
        self.assertEqual(releases[-1][2], {'move_tag': True, 'replace_assets': True})

    def test_changed_apk_replaces_track_even_without_a_candidate_manifest_diff(self):
        events = self.run_publish(True)
        self.assertEqual(events[0:2], ['apk-compare', 'commit'])
        self.assertEqual(events[-1], 'docs')
        releases = [event for event in events if isinstance(event, tuple)]
        self.assertEqual(len(releases), 2)
        self.assertEqual(releases[-1][2], {'move_tag': True, 'replace_assets': True})


class DeferredDocsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'scripts/autoupdate').mkdir(parents=True)
        self.plan = {'version': '3.5.0-beta.1', 'commit': 'b' * 40,
                     'module_revision': 42, 'mobile_version_code': 30500}
        (self.root / 'scripts/autoupdate/config.json').write_text(json.dumps({
            'repository': '84593320z/agent2api-magisk',
            'last_plan': publish.checkpoint_plan(self.plan),
        }), encoding='utf-8')
        self.head = 'c' * 40
        self.remote = 'd' * 40
        self.calls = []

    def git(self, *args):
        self.calls.append(args)
        if args == ('rev-parse', 'HEAD'):
            return self.head
        if args == ('checkout', '--detach', self.remote):
            self.head = self.remote
        return ''

    def test_docs_fast_forward_from_recovery_checkpoint_to_main(self):
        with (patch.object(publish, 'ROOT', self.root),
              patch.object(publish, 'git', side_effect=self.git),
              patch.object(publish, 'api', return_value={'object': {'sha': self.remote}}),
              patch.object(publish, 'sync_docs', return_value=[])):
            self.assertEqual(publish.commit_docs(self.plan, 'a' * 64), self.remote)
        self.assertIn(('merge-base', '--is-ancestor', 'c' * 40, self.remote), self.calls)
        self.assertIn(('checkout', '--detach', self.remote), self.calls)

    def test_docs_reject_a_newer_main_checkpoint(self):
        document = json.loads((self.root / 'scripts/autoupdate/config.json').read_text())
        document['last_plan']['module_revision'] = 43
        (self.root / 'scripts/autoupdate/config.json').write_text(json.dumps(document), encoding='utf-8')
        with (patch.object(publish, 'ROOT', self.root),
              patch.object(publish, 'git', side_effect=self.git),
              patch.object(publish, 'api', return_value={'object': {'sha': self.remote}}),
              self.assertRaisesRegex(ValueError, 'checkpoint differs')):
            publish.commit_docs(self.plan, 'a' * 64)


if __name__ == '__main__':
    unittest.main()
