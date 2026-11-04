"""Refresh source snapshots and patch from the isolated upstream worktree."""
from pathlib import Path
import hashlib, json, subprocess
BASE = Path(__file__).resolve().parents[2]
UPGRADE = BASE / 'upgrade-3.4.1'
WORK = BASE / 'mobile-build-3.4.1'
EVIDENCE = UPGRADE / 'upgrade-evidence/mobile'
EVIDENCE.mkdir(parents=True, exist_ok=True)
rels = ['App.tsx', 'api/switches.ts', 'components/GatewaySwitches.tsx', 'lib/discover.ts', 'pages/ServersPage.tsx', 'pages/SettingsPage.tsx', 'state/store.ts']
# Existing snapshots and patch must be read before replacement.
for rel in rels:
    dest = UPGRADE / 'apk-mod/src' / rel
    dest.read_bytes()
    dest.write_bytes((WORK / 'desktop-tauri/mobile/src' / rel).read_bytes())
patch = UPGRADE / 'apk-mod/a2a-mobile-mod.patch'
patch.read_bytes()
# --3way puts every modified/new file in the worktree index.
patch.write_bytes(subprocess.check_output(['git', '-C', str(WORK), 'diff', '--cached', '--binary', 'HEAD', '--', 'desktop-tauri/mobile/src']))
manifest = {'upstream_tag': 'v3.4.1', 'upstream_commit': subprocess.check_output(['git', '-C', str(WORK), 'rev-parse', 'HEAD'], text=True).strip(), 'snapshots': {rel: hashlib.sha256((UPGRADE / 'apk-mod/src' / rel).read_bytes()).hexdigest() for rel in rels}, 'patch_sha256': hashlib.sha256(patch.read_bytes()).hexdigest()}
manifest_path = EVIDENCE / 'source-manifest.json'
if manifest_path.exists(): manifest_path.read_bytes()
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
print(json.dumps(manifest, indent=2))
