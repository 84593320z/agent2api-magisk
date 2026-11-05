"""Offline device-boundary tests for the new APK release updater."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'module/libexec/a2a').read_text(encoding='utf-8')
MATCH = re.search(r'^cmd_apk_update\(\) \(\n(.*?)^\)\n', SOURCE, re.M | re.S)
assert MATCH, 'cmd_apk_update function not found'
FUNCTION = 'cmd_apk_update() (\n' + MATCH.group(1) + ')\n'
SHA = 'a' * 64


class ApkUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='a2a-apk-update-test-')
        self.root = Path(self.tmp.name)
        (self.root / 'libexec').mkdir()
        (self.root / 'run').mkdir()
        (self.root / 'libexec/updater.sh').write_text('''
upd_curl() {
  printf '%s\\n' "$*" >>"$RUNDIR/curl.args"
  _out=""; _url=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) _out="$2"; shift 2 ;;
      *) _url="$1"; shift ;;
    esac
  done
  case "$_url" in
    */SHA256SUMS.txt) printf '%s  Agent2API-%s-mod.apk\\n' "$APK_SHA" "$APK_VERSION" >"$_out" ;;
    */Agent2API-*-mod.apk) printf 'apk bytes' >"$_out" ;;
    *) return 1 ;;
  esac
}
mirror_url() { printf '%s' "$1"; }
''', encoding='utf-8')

    def tearDown(self):
        self.tmp.cleanup()

    def run_update(self, argument='', actual_sha=SHA, uid='0'):
        version = argument or '3.4.2'
        script = f'''
MODDIR='{self.root.as_posix()}'
RUNDIR='{(self.root / 'run').as_posix()}'
APK_SHA={SHA}
APK_VERSION={version}
say() {{ printf '%s\\n' "$*"; }}
id() {{ [ "${{1:-}}" = -u ] && printf '%s\\n' '{uid}'; }}
module_version() {{ printf '%s\\n' 'v3.4.2 (magisk.38)'; }}
cfg_get() {{ case "$1" in apk_repo) printf '%s\\n' '84593320z/agent2api-magisk' ;; github_mirror) printf '%s\\n' '' ;; esac; }}
sha256_of() {{ printf '%s' '{actual_sha}'; }}
pm() {{ printf '%s\\n' "$*" >>"$RUNDIR/pm.args"; printf 'Success\\n'; }}
{FUNCTION}
cmd_apk_update {argument}
'''
        path = self.root / 'case.sh'
        path.write_text(script, encoding='utf-8')
        shell = os.environ.get('A2A_SH') or shutil.which('sh')
        self.assertTrue(shell, 'POSIX sh is required')
        return subprocess.run([shell, str(path)], text=True, encoding='utf-8',
                              capture_output=True, timeout=20)

    def test_default_version_downloads_with_redirects_and_installs(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / 'run/curl.args').read_text(encoding='utf-8').splitlines()
        self.assertEqual(len(calls), 2)
        self.assertTrue(all('-fL' in call for call in calls))
        self.assertIn('/apk-v3.4.2-mod/SHA256SUMS.txt', calls[0])
        self.assertIn('/apk-v3.4.2-mod/Agent2API-3.4.2-mod.apk', calls[1])
        self.assertIn('install -r', (self.root / 'run/pm.args').read_text(encoding='utf-8'))
        self.assertIn('APK 已更新到 3.4.2-mod', result.stdout)
        self.assertEqual(list((self.root / 'run').glob('apk-update.*')), [])

    def test_hash_mismatch_never_calls_package_manager(self):
        result = self.run_update(actual_sha='b' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('APK 校验失败', result.stdout)
        self.assertFalse((self.root / 'run/pm.args').exists())

    def test_explicit_version_and_nonroot_validation(self):
        result = self.run_update('3.4.1')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('/apk-v3.4.1-mod/', (self.root / 'run/curl.args').read_text(encoding='utf-8'))
        (self.root / 'run/curl.args').unlink()
        result = self.run_update(uid='1000')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('需要 root', result.stdout)
        self.assertFalse((self.root / 'run/curl.args').exists())


if __name__ == '__main__':
    unittest.main()
