# -*- coding: utf-8 -*-
"""Verify the split frontend snapshot and execute real-source behavior regressions.

Run: python test/verify_frontend.py
Requires Node >=22.13 with node:module.stripTypeScriptTypes. Set NODE_BINARY to
select a runtime. Missing source/runtime is a failure, never a silent SKIP.
"""
import os
import shutil
import subprocess
import sys
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
ROOT = TEST_DIR.parent
SRC = ROOT / 'apk-mod' / 'src'


def main() -> int:
    checks = []

    def ck(name, ok):
        checks.append(bool(ok))
        print(('  ok   ' if ok else '  FAIL ') + name, flush=True)

    required = [SRC / 'components' / 'GatewaySwitches.tsx', SRC / 'api' / 'switches.ts',
                SRC / 'pages' / 'SettingsPage.tsx', ROOT / 'apk-mod' / 'a2a-mobile-mod.patch',
                TEST_DIR / 'verify_frontend_runtime.mjs']
    for file in required:
        ck('required source: ' + str(file.relative_to(ROOT)), file.is_file())
    if not all(checks):
        return 1
    page = (SRC / 'pages' / 'SettingsPage.tsx').read_text(encoding='utf-8')
    ck('SettingsPage uses split GatewaySwitches component',
       "from '../components/GatewaySwitches'" in page and '<GatewaySwitches' in page)

    # Integrity checks complement (not replace) the dynamic state/API tests below.
    patch = (ROOT / 'apk-mod' / 'a2a-mobile-mod.patch').read_text(encoding='utf-8').splitlines(keepends=True)
    for rel in ('api/switches.ts', 'components/GatewaySwitches.tsx', 'lib/discover.ts'):
        marker = '+++ b/desktop-tauri/mobile/src/' + rel
        positions = [i for i, line in enumerate(patch) if line.rstrip() == marker]
        matches = False
        if len(positions) == 1:
            start = positions[0]
            end = next((i for i in range(start + 1, len(patch)) if patch[i].startswith('diff --git ')), len(patch))
            added = ''.join(line[1:] for line in patch[start + 1:end] if line.startswith('+'))
            matches = added == (SRC / rel).read_text(encoding='utf-8')
        ck('patch new-file snapshot matches: ' + rel, matches)

    node = os.environ.get('NODE_BINARY') or shutil.which('node')
    ck('Node runtime available (NODE_BINARY or PATH)', bool(node))
    if not node:
        return 1
    print('\nExecuting real component/API runtime regression:', flush=True)
    result = subprocess.run([node, '--disable-warning=ExperimentalWarning',
                             str(TEST_DIR / 'verify_frontend_runtime.mjs')], cwd=ROOT)
    ck('runtime behavior suite exits zero', result.returncode == 0)
    passed = sum(checks)
    print('\n=== integration: %d checked / %d passed / %d failed ===' %
          (len(checks), passed, len(checks) - passed))
    return 0 if all(checks) else 1


if __name__ == '__main__':
    sys.exit(main())
