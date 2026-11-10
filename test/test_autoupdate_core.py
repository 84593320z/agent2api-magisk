"""Core supply-chain checks. Offline: network/git effects mocked; ZIP tests use scratch."""
import copy
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/autoupdate'))
import control
import bundle
import mobile
import publish


def fixture():
    baseline = {'upstream': 'aimod-cc/Agent2API', 'repository': '84593320z/agent2api-magisk',
                'branch': 'main', 'certificate_sha256': 'trusted', 'last_version': '1.2.2',
                'last_commit': 'a' * 40, 'module_revision': 6, 'mobile_version_code': 10202,
                'asset': 'server.tar.gz', 'max_asset_bytes': 100000, 'max_source_bytes': 200000}
    plan = {'changed': True, 'tag': 'v1.2.3', 'version': '1.2.3', 'commit': 'b' * 40,
            'module_revision': 7, 'mobile_version_code': 10203, 'upstream': baseline['upstream'], 'run_id': '42'}
    candidate = dict(baseline, last_version=plan['version'], last_commit=plan['commit'],
                     module_revision=7, mobile_version_code=10203, last_plan=plan)
    return baseline, plan, candidate


class ConfigTests(unittest.TestCase):
    def test_exact_checkpoint_and_every_fixed_key(self):
        baseline, plan, candidate = fixture()
        bundle.validate_config(baseline, candidate, plan)
        for key in baseline:
            if key in {'last_version', 'last_commit', 'module_revision', 'mobile_version_code'}:
                continue
            with self.subTest(key=key):
                bad = dict(candidate, **{key: 'tampered'})
                with self.assertRaises(ValueError):
                    bundle.validate_config(baseline, bad, plan)
        for key in ('last_plan', 'module_revision', 'mobile_version_code', 'last_version', 'last_commit'):
            with self.subTest(key=key):
                bad = dict(candidate, **{key: None})
                with self.assertRaises(ValueError):
                    bundle.validate_config(baseline, bad, plan)
        with self.assertRaises(ValueError):
            bundle.validate_config(baseline, dict(candidate, extra='injected'), plan)

    def test_bundle_validates_configuration_before_any_write(self):
        baseline, plan, candidate = fixture()
        candidate['certificate_sha256'] = 'attacker'
        with tempfile.TemporaryDirectory(prefix='autoupdate-core-') as temp:
            root = Path(temp)
            config = root / 'scripts/autoupdate/config.json'
            config.parent.mkdir(parents=True)
            config.write_text(json.dumps(baseline), encoding='utf-8')
            rows = []
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, 'w') as z:
                for name, data in [('module/seed/ui/new.js', b'injected'), ('scripts/autoupdate/config.json', json.dumps(candidate).encode())]:
                    z.writestr(name, data)
                    rows.append({'path': name, 'deleted': False, 'sha256': hashlib.sha256(data).hexdigest()})
                z.writestr('manifest.json', json.dumps(rows))
            archive.seek(0)
            with patch.object(bundle, 'ROOT', root), self.assertRaises(ValueError):
                bundle.apply(archive, plan=plan)
            self.assertEqual(json.loads(config.read_text()), baseline)
            self.assertFalse((root / 'module/seed/ui/new.js').exists())


class CompletionTests(unittest.TestCase):
    def setUp(self):
        self.baseline, self.plan, self.config = fixture()
        self.commit = 'c' * 40
        self.rebuild()

    def rebuild(self):
        """(Re)build the published releases and asset bodies from the current plan."""
        self.releases = []
        self.refs = {}
        self.bodies = {}
        ident = 1
        for tag, names in control.release_specs(self.plan).items():
            payloads = {n: (json.dumps(self.plan).encode() if n == 'plan.json' else n.encode()) for n in names}
            payloads['SHA256SUMS.txt'] = ''.join(hashlib.sha256(payloads[n]).hexdigest() + '  ' + n + '\n' for n in sorted(names)).encode()
            assets = []
            for name, data in payloads.items():
                self.bodies[ident] = data
                assets.append({'name': name, 'id': ident, 'size': len(data), 'state': 'uploaded', 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()})
                ident += 1
            self.releases.append({'tag_name': tag, 'draft': False, 'prerelease': False, 'assets': assets})
            self.refs[tag] = self.commit

    def request(self, url, token=None, binary=False):
        if '/git/matching-refs/tags/' in url:
            tag = url.split('/git/matching-refs/tags/')[1]
            return [{'ref': 'refs/tags/' + tag, 'object': {'type': 'commit', 'sha': self.refs[tag]}}] if tag in self.refs else []
        if '/releases/assets/' in url:
            return self.bodies[int(url.rsplit('/', 1)[1])]
        return self.releases

    def complete(self):
        with patch.object(control, 'request', side_effect=self.request):
            return control.releases_complete(self.config, self.plan)

    def test_complete_downloaded_release(self):
        self.assertTrue(self.complete())

    def test_prerelease_flag_must_match_plan(self):
        """A beta release is complete only when the published flag matches the plan."""
        self.plan['prerelease'] = True
        self.rebuild()
        self.assertFalse(self.complete())
        for release in self.releases:
            release['prerelease'] = True
        self.assertTrue(self.complete())

    def test_missing_extra_draft_corrupt_size_digest_and_checksums(self):
        original = copy.deepcopy(self.releases)
        bodies = dict(self.bodies)
        for mode in ('missing', 'extra', 'draft', 'size', 'digest', 'bytes', 'checksums'):
            with self.subTest(mode=mode):
                self.releases = copy.deepcopy(original)
                self.bodies = dict(bodies)
                release = self.releases[0]
                asset = release['assets'][0]
                if mode == 'missing':
                    release['assets'].pop()
                elif mode == 'extra':
                    release['assets'].append(dict(asset, name='unexpected.bin'))
                elif mode == 'draft':
                    release['draft'] = True
                elif mode == 'size':
                    asset['size'] += 1
                elif mode == 'digest':
                    asset['digest'] = ''
                elif mode == 'bytes':
                    self.bodies[asset['id']] = b'corrupt'
                else:
                    checksum = next(a for a in release['assets'] if a['name'] == 'SHA256SUMS.txt')
                    data = b'0' * 64 + b'  missing.bin\n'
                    self.bodies[checksum['id']] = data
                    checksum.update(size=len(data), digest='sha256:' + hashlib.sha256(data).hexdigest())
                self.assertFalse(self.complete())

    def test_tag_disagreement_rejected(self):
        self.refs[next(iter(self.refs))] = 'd' * 40
        with self.assertRaises(ValueError):
            self.complete()

    def test_old_checkpoint_precedes_upstream_lookup(self):
        with patch.object(control, 'releases_complete', return_value=False), patch.object(control, 'detect') as detect:
            self.assertEqual(control.select_plan(self.config), dict(self.plan, retry=True))
            detect.assert_not_called()


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.baseline, self.plan, self.config = fixture()
        self.head, self.checkpoint = 'd' * 40, 'c' * 40
        self.calls = []

    def git(self, *args):
        self.calls.append(args)
        if args == ('rev-parse', 'HEAD'):
            return self.head
        if args == ('rev-parse', '--is-shallow-repository'):
            return 'true'
        if args[0] == 'rev-list':
            return 'a' * 40 + '\n' + self.checkpoint + '\n' + self.head
        if args[0] == 'show':
            return json.dumps(self.baseline if args[1].startswith('a' * 40) else self.config)
        return ''

    def recover(self, refs):
        with patch.object(publish, 'git', side_effect=self.git), patch.object(publish, 'api', return_value={'object': {'sha': self.head}}), patch.object(publish, 'release_refs', return_value=refs):
            return publish.recovery_commit(dict(self.plan, retry=True))

    def test_existing_tag_uses_checkpoint_not_latest_main(self):
        self.assertEqual(self.recover({'tag': self.checkpoint}), self.checkpoint)
        self.assertIn(('fetch', '--unshallow', 'origin', 'main'), self.calls)
        self.assertIn(('merge-base', '--is-ancestor', self.checkpoint, self.head), self.calls)

    def test_no_tag_locates_first_persisted_checkpoint(self):
        self.assertEqual(self.recover({}), self.checkpoint)

    def test_unrelated_tag_or_modified_checkpoint_rejected(self):
        original = self.git
        def unrelated(*args):
            if args[0] == 'merge-base':
                raise subprocess.CalledProcessError(1, args)
            return original(*args)
        with patch.object(publish, 'git', side_effect=unrelated), patch.object(publish, 'api', return_value={'object': {'sha': self.head}}), patch.object(publish, 'release_refs', return_value={'tag': self.checkpoint}), self.assertRaises(subprocess.CalledProcessError):
            publish.recovery_commit(self.plan)
        self.config['last_plan'] = dict(self.plan, run_id='different')
        with self.assertRaises(ValueError):
            self.recover({'tag': self.checkpoint})


class PrereleaseTests(unittest.TestCase):
    """Prereleases stay opt-in, sort below their stable release, and never roll back."""

    digest = 'sha256:' + 'a' * 64

    def release(self, tag, prerelease):
        return {'tag_name': tag, 'draft': False, 'prerelease': prerelease, 'id': len(tag),
                'published_at': '2026-11-09T17:54:23Z',
                'assets': [{'id': 7, 'name': 'server.tar.gz', 'size': 1024, 'digest': self.digest}]}

    @staticmethod
    def ref(url):
        return {'object': {'type': 'commit', 'sha': 'd' * 40}}

    def detect(self, releases, allow_prerelease=False, last_version='1.2.2'):
        baseline, _, _ = fixture()
        baseline['last_version'] = last_version
        return control.detect(baseline, releases=releases, ref_lookup=self.ref, allow_prerelease=allow_prerelease)

    def test_semver_precedence(self):
        ordered = ['1.2.2', '1.2.3-beta.1', '1.2.3-beta.9', '1.2.3-beta.10', '1.2.3-rc.1', '1.2.3']
        keys = [control.version(value) for value in ordered]
        self.assertEqual(keys, sorted(keys))
        self.assertEqual(len(set(keys)), len(keys))

    def test_detection_ignores_prerelease_by_default(self):
        plan = self.detect([self.release('v1.2.3', False), self.release('v1.3.0-beta.1', True)],
                           last_version='1.2.3')
        self.assertFalse(plan['changed'])
        self.assertEqual(plan['version'], '1.2.3')

    def test_manual_switch_accepts_prerelease(self):
        plan = self.detect([self.release('v1.2.3', False), self.release('v1.3.0-beta.1', True)],
                           allow_prerelease=True, last_version='1.2.3')
        self.assertTrue(plan['changed'])
        self.assertEqual(plan['version'], '1.3.0-beta.1')
        self.assertEqual(plan['tag'], 'v1.3.0-beta.1')
        self.assertIs(plan['prerelease'], True)
        self.assertEqual(plan['module_revision'], 7)
        self.assertEqual(plan['mobile_version_code'], 10300)

    def test_pinned_prerelease_is_not_downgraded(self):
        plan = self.detect([self.release('v1.2.3', False)], last_version='1.3.0-beta.1')
        self.assertFalse(plan['changed'])
        plan = self.detect([self.release('v1.2.3', False), self.release('v1.3.0', False)],
                           last_version='1.3.0-beta.1')
        self.assertTrue(plan['changed'])
        self.assertEqual(plan['version'], '1.3.0')
        self.assertIs(plan['prerelease'], False)

    def test_apk_identity_accepts_prerelease_suffix(self):
        self.assertEqual(mobile.version('v1.3.0-beta.1', 10300), '1.3.0-beta.1')
        for bad in ('1.3.0-beta.1', 'v1.3.0-beta..1', 'v1.3.0-'):
            with self.subTest(tag=bad):
                with self.assertRaises(mobile.MobileError):
                    mobile.version(bad, 10300)


if __name__ == '__main__':
    unittest.main()
