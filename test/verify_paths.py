# -*- coding: utf-8 -*-
"""RR-09 回归：两个 verify 脚本的 posix() 路径转换。

旧实现无条件 `return '/' + s[0].lower() + s[2:]`，把 Linux/MSYS 的绝对
路径 /tmp/repro.sh 变成 //mp/repro.sh —— 在 Linux 主机上直接找不到文件。
正确的语义只有一种：**Windows 盘符路径**才转 /c/...，其余原样返回。

只读源码，不执行被测脚本（两个脚本在 import 时就会跑完整验证）。
"""
import ast
import sys
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
CASES = [
    (TEST_DIR / 'verify_fixes.py', 'verify_fixes.py'),
    (TEST_DIR / 'verify_loop.py', 'verify_loop.py'),
]

CHECKS = [
    ('/tmp/repro.sh', '/tmp/repro.sh'),
    ('/data/adb/agent2api', '/data/adb/agent2api'),
    ('C:\\Users\\x\\repro.sh', '/c/Users/x/repro.sh'),
    ('c:/Users/x/repro.sh', '/c/Users/x/repro.sh'),
    ('relative/path.sh', 'relative/path.sh'),
]


def load_posix(path: Path):
    """从源码里切出 posix 函数并单独编译，避免 import 触发整个验证流程。"""
    tree = ast.parse(path.read_text(encoding='utf-8'))
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == 'posix':
            mod = ast.Module(body=[node], type_ignores=[])
            ns = {}
            exec(compile(mod, str(path), 'exec'), ns)  # noqa: S102 - 只执行被测的纯函数
            return ns['posix']
    raise SystemExit('%s 里找不到 posix()' % path)


def main() -> int:
    total = passed = 0
    bad = []
    for path, label in CASES:
        if not path.is_file():
            print('SKIP 缺少 %s' % path)
            continue
        fn = load_posix(path)
        for src, want in CHECKS:
            total += 1
            got = fn(src)
            if got == want:
                passed += 1
                print('  ok   %s %r -> %r' % (label, src, got))
            else:
                bad.append((label, src, want, got))
                print('  FAIL %s %r 期望 %r 实际 %r' % (label, src, want, got))
    print('\n=== %d checked / %d passed / %d failed ===' % (total, passed, len(bad)))
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
