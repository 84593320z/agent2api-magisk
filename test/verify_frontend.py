# -*- coding: utf-8 -*-
"""RR-08 回归：开关页 load() 不得复用上一次的已知状态。

现场：第一次 GET 成功（debug=true），第二次 GET 因为端点 500 返回空对象。
旧实现 `setState(current => ({...current, ...next}))` 会保留 debug=true，
开关看起来仍然可点，用户拨下去必然失败；正确行为是未返回的键变成
undefined，由 render 端 disabled 拦掉。
"""
import re
import sys
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
PAGE = TEST_DIR.parent / 'apk-mod' / 'src' / 'pages' / 'SettingsPage.tsx'

checks = []


def ck(name, ok, detail=''):
    checks.append((name, bool(ok), detail))


def slice_fn(src: str, start_marker: str, end_marker: str) -> str:
    i = src.find(start_marker)
    if i < 0:
        return ''
    j = src.find(end_marker, i)
    if j < 0:
        return ''
    return src[i:j + len(end_marker)]


def main() -> int:
    if not PAGE.is_file():
        print('SKIP 缺少 %s' % PAGE)
        return 0
    src = PAGE.read_text(encoding='utf-8')

    body = slice_fn(src, 'const load = useCallback(async (silent: boolean) => {', '}, [])')
    ck('找到 GatewaySwitches.load', bool(body))
    if body:
        # 注释里会引用旧实现（`{...current}`），只看代码本身
        code = ' '.join(line.split('//')[0] for line in body.splitlines())
        ck('load 不再展开旧 current',
           '{ ...current }' not in code and '{...current}' not in code,
           'load 代码里仍出现 {...current}')
        ck('load 从空对象构造', re.search(r'const merged:\s*SwitchState\s*=\s*\{\s*\}', body) is not None)
        ck('load 用服务端结果覆盖', 'for (const key of Object.keys(next)' in body)
        ck('load 保留在途乐观值', 'pending.current' in body)
        # 关键语义：未返回的键必须消失（不是复制旧值）
        ck('load 丢弃未返回键', 'merged[key] = pending.current' not in body)

    ck('未就绪/未知状态禁用开关',
       'disabled={!ready || value === undefined || busyIds.size > 0}' in src,
       'render 端的 disabled 表达式不匹配')

    total = len(checks)
    passed = sum(1 for _, ok, _ in checks if ok)
    for name, ok, detail in checks:
        if ok:
            print('  ok   %s' % name)
        else:
            print('  FAIL %s %s' % (name, detail))
    print('\n=== %d checked / %d passed / %d failed ===' % (total, passed, total - passed))
    return 0 if passed == total else 1


if __name__ == '__main__':
    sys.exit(main())
