"""Real-Git regression tests for NUL-delimited candidate path export."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/autoupdate'))
import bundle


@unittest.skipIf(os.name == 'nt', 'Windows forbids quote characters in Git filename fixtures')
class BundleExportGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='autoupdate-bundle-git-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'repo'
        self.repo.mkdir()
        self.git('init', '--quiet')
        self.git('config', 'user.name', 'Autoupdate Test')
        self.git('config', 'user.email', 'autoupdate@example.invalid')
        self.git('config', 'core.quotepath', 'true')
        self.git('config', 'status.renames', 'true')

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True,
                              capture_output=True, text=True, encoding='utf-8')

    def write(self, name, data):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def test_real_git_export_keeps_unicode_quotes_and_both_rename_paths(self):
        renamed = {
            'module/seed/ui/旧 "quoted".js': 'module/seed/ui/新 "名称".js',
            'module/seed/ui/离开.js': 'outside/离开.js',
            'incoming.txt': 'module/seed/ui/进入 "文件".js',
        }
        for name in [*renamed, 'module/seed/ui/plain.js']:
            self.write(name, ('initial:' + name).encode('utf-8'))
        self.git('add', '--all')
        self.git('commit', '--quiet', '-m', 'initial')

        for old, new in renamed.items():
            (self.repo / new).parent.mkdir(parents=True, exist_ok=True)
            self.git('mv', old, new)
        self.write('module/seed/ui/plain.js', b'changed')
        extra = 'module/seed/ui/额外 "页面".tsx'
        self.write(extra, b'<button>new</button>')

        archive = Path(self.temp.name) / 'candidate.zip'
        with patch.object(bundle, 'ROOT', self.repo):
            bundle.export(archive)

        with zipfile.ZipFile(archive) as z:
            rows = json.loads(z.read('manifest.json'))
            by_path = {row['path']: row for row in rows}
            self.assertEqual(len(by_path), len(rows))
            expected = {
                'module/seed/ui/plain.js',
                extra,
                renamed['module/seed/ui/旧 "quoted".js'],
                renamed['module/seed/ui/离开.js'],
                renamed['incoming.txt'],
                *renamed,
            }
            # Old allowed paths are exported as deletions even when their rename
            # destination is outside the allowlist; unallowed paths never enter.
            expected.remove('outside/离开.js')
            expected.remove('incoming.txt')
            self.assertEqual(set(by_path), expected)
            self.assertNotIn('outside/离开.js', by_path)
            self.assertNotIn('incoming.txt', by_path)
            for old in ('module/seed/ui/旧 "quoted".js', 'module/seed/ui/离开.js'):
                self.assertTrue(by_path[old]['deleted'])
                self.assertNotIn(old, z.namelist())
            for new in (renamed['module/seed/ui/旧 "quoted".js'], renamed['incoming.txt'], extra):
                self.assertFalse(by_path[new]['deleted'])
                self.assertEqual(z.read(new), (self.repo / new).read_bytes())

    def test_real_git_export_has_no_allowed_candidate_false_success(self):
        self.write('module/seed/ui/初始.js', b'old')
        self.git('add', '--all')
        self.git('commit', '--quiet', '-m', 'initial')
        self.git('mv', 'module/seed/ui/初始.js', 'module/seed/ui/重命名 "之后".js')
        archive = Path(self.temp.name) / 'candidate.zip'
        with patch.object(bundle, 'ROOT', self.repo):
            bundle.export(archive)
        with zipfile.ZipFile(archive) as z:
            rows = json.loads(z.read('manifest.json'))
        self.assertEqual({row['path'] for row in rows}, {
            'module/seed/ui/初始.js', 'module/seed/ui/重命名 "之后".js',
        })


if __name__ == '__main__':
    unittest.main()
