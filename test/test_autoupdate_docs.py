import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/autoupdate'))
from docs_sync import BEGIN, END, sync


PLAN = {
    'version': '3.4.2',
    'tag': 'v3.4.2',
    'commit': 'e8bed7397aaf9d8962489074557c2f1f1a8d4f97',
    'module_revision': 38,
    'mobile_version_code': 30402,
}
PROP = '''id=agent2api
version=v3.4.2 (magisk.38)
versionCode=2026110538
updateJson=https://raw.githubusercontent.com/84593320z/agent2api-magisk/main/update.json
'''
ZIP_SHA = '1d341f0d1dc2c54012ea4c03fd3fef7896380dabe7128e6ecf6c070d702cb893'


class DocsSyncTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / 'module').mkdir()
        (self.root / 'module/module.prop').write_text(PROP, encoding='utf-8')
        (self.root / 'README.md').write_text(
            '# demo\n\n' + BEGIN + '\nold\n' + END + '\n\nhistory stays\n', encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def test_sync_is_deterministic_and_preserves_history(self):
        repo = '84593320z/agent2api-magisk'
        self.assertEqual(sync(self.root, PLAN, repo, ZIP_SHA), ['README.md', 'update.json'])
        readme = (self.root / 'README.md').read_text(encoding='utf-8')
        self.assertIn('## 最新版本：v3.4.2 / magisk.38', readme)
        self.assertIn('/releases/tag/apk-v3.4.2-mod', readme)
        self.assertIn('`3.4.2 / 30402`', readme)
        self.assertTrue(readme.endswith('history stays\n'))
        document = json.loads((self.root / 'update.json').read_text(encoding='utf-8'))
        self.assertEqual(document, {
            'version': 'v3.4.2 (magisk.38)',
            'versionCode': 2026110538,
            'zipUrl': 'https://github.com/84593320z/agent2api-magisk/releases/download/v3.4.2-magisk.38/agent2api-magisk-v3.4.2-magisk.38-arm64.zip',
            'changelog': 'https://github.com/84593320z/agent2api-magisk/releases/tag/v3.4.2-magisk.38',
            'sha256': ZIP_SHA,
        })
        self.assertEqual(sync(self.root, PLAN, repo, ZIP_SHA), [])

    def test_missing_markers_fail_closed(self):
        (self.root / 'README.md').write_text('# no markers\n', encoding='utf-8')
        with self.assertRaisesRegex(ValueError, 'markers'):
            sync(self.root, PLAN, '84593320z/agent2api-magisk', ZIP_SHA)
        self.assertFalse((self.root / 'update.json').exists())

    def test_bad_zip_hash_fails_before_writing(self):
        with self.assertRaisesRegex(ValueError, 'SHA-256'):
            sync(self.root, PLAN, '84593320z/agent2api-magisk', 'not-a-hash')
        self.assertIn('old', (self.root / 'README.md').read_text(encoding='utf-8'))
        self.assertFalse((self.root / 'update.json').exists())


if __name__ == '__main__':
    unittest.main()
