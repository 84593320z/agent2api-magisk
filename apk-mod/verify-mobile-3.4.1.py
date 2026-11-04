"""Verify all seven snapshots, exact patch and retained upstream 3.4.1 features."""
from pathlib import Path
import hashlib, json, subprocess
BASE = Path(__file__).resolve().parents[2]
ROOT = BASE / 'upgrade-3.4.1'
WORK = BASE / 'mobile-build-3.4.1'
manifest = json.loads((ROOT / 'upgrade-evidence/mobile/source-manifest.json').read_text())
checks = []
def ck(label, value):
    checks.append(bool(value))
    print(('PASS ' if value else 'FAIL ') + label)
def git(*args):
    return subprocess.check_output(['git', '-C', str(WORK), *args])
ck('exact upstream commit', git('rev-parse', 'HEAD').decode().strip() == '3ff4b8215d0d65c3451ca74923e90964ed7dbf59')
for rel, digest in manifest['snapshots'].items():
    snap = (ROOT / 'apk-mod/src' / rel).read_bytes()
    ck('snapshot bytes and hash: ' + rel, snap == (WORK / 'desktop-tauri/mobile/src' / rel).read_bytes() and hashlib.sha256(snap).hexdigest() == digest)
patch = ROOT / 'apk-mod/a2a-mobile-mod.patch'
ck('patch matches complete staged mobile delta', patch.read_bytes() == git('diff', '--cached', '--binary', 'HEAD', '--', 'desktop-tauri/mobile/src'))
ck('patch hash', hashlib.sha256(patch.read_bytes()).hexdigest() == manifest['patch_sha256'])
ck('patch reverse applicability', subprocess.run(['git', '-C', str(WORK), 'apply', '--reverse', '--check', str(patch)], capture_output=True).returncode == 0)
app = (ROOT / 'apk-mod/src/App.tsx').read_text(encoding='utf-8')
ck('3.4.1 ToolsPage import and tools route', "import { ToolsPage } from './pages/ToolsPage'" in app and "tools: { title: t('工具服务'), component: ToolsPage }" in app)
for rel in ['pages/ToolsPage.tsx', 'lib/assistant-attachments.ts', 'lib/assistant-image-tools.ts', 'lib/assistant-read-tools.ts', 'lib/assistantTools.ts']:
    # Git blobs are LF; checkout may be CRLF.
    actual = (WORK / 'desktop-tauri/mobile/src' / rel).read_text(encoding='utf-8')
    upstream = git('show', 'HEAD:desktop-tauri/mobile/src/' + rel).decode('utf-8')
    ck('upstream feature unchanged: ' + rel, actual == upstream)
print(f'{sum(checks)}/{len(checks)} checks passed')
raise SystemExit(0 if all(checks) else 1)
