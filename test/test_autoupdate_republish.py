"""Module-only rebuild path: same upstream version, one new module revision."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/autoupdate'))
import bundle
import control
import publish
import republish_plan


def fixture():
    plan = {'changed': True, 'tag': 'v3.5.0-beta.1', 'version': '3.5.0-beta.1', 'commit': 'b' * 40,
            'module_revision': 40, 'mobile_version_code': 30500, 'prerelease': 'beta.1',
            'upstream': 'aimod-cc/Agent2API', 'asset_sha256': 'c' * 64, 'run_id': '7',
            'republish': True}
    baseline = {'upstream': 'aimod-cc/Agent2API', 'repository': '84593320z/agent2api-magisk',
                'branch': 'main', 'certificate_sha256': 'trusted', 'last_version': '3.5.0-beta.1',
                'last_commit': 'b' * 40, 'module_revision': 39, 'mobile_version_code': 30500,
                'asset': 'server.tar.gz', 'max_asset_bytes': 100000, 'max_source_bytes': 200000}
    candidate = dict(baseline, module_revision=40, last_plan=plan)
    return baseline, plan, candidate


class PlanTests(unittest.TestCase):
    def test_plan_reuses_the_recorded_checkpoint(self):
        baseline, plan, _ = fixture()
        config = dict(baseline, last_plan=dict(plan, module_revision=39, republish=False))
        built = republish_plan.build_plan(config, '99')
        self.assertEqual(built['module_revision'], 40)
        self.assertEqual(built['mobile_version_code'], 30500)
        self.assertEqual(built['version'], '3.5.0-beta.1')
        self.assertEqual(built['commit'], 'b' * 40)
        self.assertTrue(built['republish'])
        self.assertFalse(built['smoke'])
        self.assertEqual(built['run_id'], '99')

    def test_plan_requires_a_checkpoint(self):
        baseline, _, _ = fixture()
        with self.assertRaises(ValueError):
            republish_plan.build_plan(dict(baseline))

    def test_retry_flag_does_not_leak_into_the_new_plan(self):
        baseline, plan, _ = fixture()
        config = dict(baseline, last_plan=dict(plan, module_revision=39, retry=True))
        self.assertNotIn('retry', republish_plan.build_plan(config))

    def test_detection_with_real_work_wins_over_the_rebuild(self):
        with tempfile.TemporaryDirectory() as temp:
            plan_file = Path(temp)/'plan.json'
            for pending in ({'changed': True}, {'changed': False, 'retry': True}):
                with self.subTest(pending=pending):
                    plan_file.write_text(json.dumps(pending), encoding='utf-8')
                    self.assertTrue(republish_plan.pending(plan_file))
                    self.assertEqual(republish_plan.main(plan_file), 1)
                    self.assertEqual(json.loads(plan_file.read_text(encoding='utf-8')), pending)

    def test_idle_detection_leaves_room_for_the_rebuild(self):
        with tempfile.TemporaryDirectory() as temp:
            plan_file = Path(temp)/'plan.json'
            plan_file.write_text(json.dumps({'changed': False}), encoding='utf-8')
            self.assertFalse(republish_plan.pending(plan_file))
            self.assertFalse(republish_plan.pending(Path(temp)/'absent.json'))


class ConfigTests(unittest.TestCase):
    def test_candidate_must_advance_exactly_one_revision(self):
        baseline, plan, candidate = fixture()
        bundle.validate_config(baseline, candidate, plan)
        for revision in (39, 41):
            with self.subTest(revision=revision):
                with self.assertRaises(ValueError):
                    bundle.validate_config(baseline, dict(candidate, module_revision=revision), plan)

    def test_candidate_must_keep_the_published_version_and_apk(self):
        baseline, plan, candidate = fixture()
        for key, value in (('mobile_version_code', 30501), ('last_version', '3.5.0'),
                           ('last_commit', 'd' * 40)):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    bundle.validate_config(baseline, dict(candidate, **{key: value}), plan)

    def test_normal_upgrade_still_requires_a_new_apk_code(self):
        baseline, plan, candidate = fixture()
        plan = dict(plan, republish=False, version='3.6.0')
        baseline = dict(baseline, last_version='3.5.0-beta.1')
        candidate = dict(candidate, last_version='3.6.0', last_plan=plan)
        with self.assertRaises(ValueError):
            bundle.validate_config(baseline, candidate, plan)


class PublishBranchTests(unittest.TestCase):
    def test_republish_is_detected(self):
        baseline, plan, _ = fixture()
        self.assertTrue(publish.is_republish(baseline, plan))

    def test_recovery_of_the_same_revision_is_not_a_republish(self):
        baseline, plan, _ = fixture()
        self.assertFalse(publish.is_republish(baseline, dict(plan, module_revision=39)))
        self.assertFalse(publish.is_republish(dict(baseline, module_revision=40), plan))

    def test_new_upstream_version_is_not_a_republish(self):
        baseline, plan, _ = fixture()
        self.assertFalse(publish.is_republish(baseline, dict(plan, version='3.6.0')))


class AdvanceTests(unittest.TestCase):
    def run_advance(self, baseline, plan):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp)/'config.json'
            config.write_text(json.dumps(baseline), encoding='utf-8')
            plan_file = Path(temp)/'plan.json'
            plan_file.write_text(json.dumps(plan), encoding='utf-8')
            subprocess.run([sys.executable, str(ROOT/'scripts/autoupdate/control.py'), 'advance',
                            '--config', str(config), '--plan', str(plan_file)], check=True,
                           capture_output=True, text=True)
            return json.loads(config.read_text(encoding='utf-8'))

    def test_advance_accepts_the_republish_plan(self):
        baseline, plan, _ = fixture()
        advanced = self.run_advance(baseline, plan)
        self.assertEqual(advanced['module_revision'], 40)
        self.assertEqual(advanced['last_version'], '3.5.0-beta.1')
        self.assertEqual(advanced['last_plan'], plan)

    def test_advance_rejects_a_jumped_revision(self):
        baseline, plan, _ = fixture()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_advance(baseline, dict(plan, module_revision=41))

    def test_advance_rejects_a_changed_upstream_commit(self):
        baseline, plan, _ = fixture()
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_advance(baseline, dict(plan, commit='d' * 40))


if __name__ == '__main__':
    unittest.main()
