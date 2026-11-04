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


if __name__ == '__main__':
    unittest.main()
