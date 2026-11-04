# -*- coding: utf-8 -*-
"""RR-12 回归：泄露签名证书必须被拦下，新钥匙能正常生成。

历史私钥 apk-mod/a2a-mod.jks 及其口令曾进过 git，任何人都能取回。修复要保证：
  1. 指纹检查会拒绝那把旧证书（大小写/带冒号的写法都要认）；
  2. 新钥匙生成在仓库外，生成后能读回同一个指纹；
  3. 生成器拒绝把私钥写进仓库目录；
  4. 发布证书指纹与泄露值不同。
没有 JDK（keytool）时只跑 1，其余 SKIP。
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / 'apk-mod' / 'sign-tool.sh'
LEAKED = 'B1:8B:0E:B2:07:83:29:A9:96:33:22:E8:7F:47:66:99:43:65:5D:B8:57:AA:06:C0:76:DD:86:83:65:C0:BF:15'
checks = []


def ck(name, ok, detail=''):
    checks.append((name, bool(ok), detail))


def run(args, **kw):
    return subprocess.run(['sh', str(TOOL)] + args, capture_output=True,
                          text=True, encoding='utf-8', errors='replace', **kw)


def main():
    if not TOOL.is_file():
        print('SKIP 缺少 %s' % TOOL)
        return 0

    r = run(['check-fingerprint', LEAKED])
    ck('带冒号的泄露指纹被拒', r.returncode == 2, r.stdout + r.stderr)
    ck('拒绝时说明原因', '泄露' in (r.stderr or ''), r.stderr)

    r = run(['check-fingerprint', LEAKED.replace(':', '').lower()])
    ck('小写无冒号写法同样被拒', r.returncode == 2, r.stdout + r.stderr)

    r = run(['check-fingerprint', 'AA' * 32])
    ck('其它指纹放行', r.returncode == 0, r.stdout + r.stderr)

    # 仓库内的目标目录必须被拒绝（不需要 keytool，先于生成检查）
    r = run(['new', '--out', str(ROOT / 'apk-mod' / 'keys-should-not-exist')])
    ck('拒绝把私钥写进仓库', r.returncode != 0 and '仓库' in (r.stderr or ''), r.stdout + r.stderr)
    ck('被拒绝时没有留下目录', not (ROOT / 'apk-mod' / 'keys-should-not-exist').exists())

    if not shutil.which('keytool'):
        print('SKIP 没有 keytool，跳过生成用例')
    else:
        work = Path(tempfile.mkdtemp(prefix='sign-test-'))
        try:
            out = work / 'keys'
            r = run(['new', '--out', str(out)])
            ck('生成新 keystore 成功', r.returncode == 0, r.stdout + r.stderr)
            ks = out / 'a2a-release.jks'
            pw = out / 'a2a-release.pass'
            ck('keystore 已生成', ks.is_file())
            ck('口令文件已生成', pw.is_file() and len(pw.read_text(encoding='utf-8').strip()) >= 32)
            r = run(['fingerprint', '--keystore', str(ks)])
            ck('能读回新证书指纹', r.returncode == 0 and bool(re.fullmatch(r'[0-9A-F]{64}', (r.stdout or '').strip())),
               r.stdout + r.stderr)
            fp = (r.stdout or '').strip()
            ck('新指纹不等于泄露指纹', fp != LEAKED.replace(':', ''))
            # 再次生成不能覆盖已有私钥
            r = run(['new', '--out', str(out)])
            ck('不覆盖已有 keystore', r.returncode != 0, r.stdout + r.stderr)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    total = len(checks)
    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        print(('  ok   ' if ok else '  FAIL ') + name + ('' if ok else '  ' + str(detail)[:300]))
    print('\n=== %d checked / %d passed / %d failed ===' % (total, passed, total - passed))
    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
