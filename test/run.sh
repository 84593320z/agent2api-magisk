#!/bin/sh
# 开发机回归入口（不需要真机、不需要 root）。
#
# 层级：
#   1. sh -n        全部模块 shell 脚本的语法检查
#   2. txn_test.sh  事务/DNS/CLI 纯 POSIX 故障注入测试（F-001..F-008 的回归）
#   3. verify 套件  test/verify_fixes.py + verify_loop.py（环境里有 python 时）
#
# 历史问题（F-010）：旧 run.sh 是 2.x 架构，cp 一个已经不存在的
# module/bin/lib.sh，README 推荐的 `dash test/run.sh` 从未跑通过。
# 本文件完全重写，只依赖当前 libexec 布局。
#
# 用法：
#   sh test/run.sh            # 语法 + 事务测试
#   sh test/run.sh --full     # 加上 Python verify 套件（需要 python3）
#   A2A_SH=/path/to/sh sh test/run.sh   # 显式指定 POSIX shell

HERE=$(cd "$(dirname "$0")" && pwd)
SRC="$HERE/../module"

# POSIX shell 选择：A2A_SH > dash > sh。
# 不再硬编码任何用户机器上的绝对路径（F-010）。
if [ -n "${A2A_SH:-}" ]; then
  SH_BIN="$A2A_SH"
elif command -v dash >/dev/null 2>&1; then
  SH_BIN=dash
else
  SH_BIN=sh
fi

FAIL=0

echo "== 1. shell 语法检查（sh -n） =="
for f in \
  "$SRC/post-fs-data.sh" \
  "$SRC/customize.sh" \
  "$SRC/service.sh" \
  "$SRC/uninstall.sh" \
  "$SRC/libexec/common.sh" \
  "$SRC/libexec/payload.sh" \
  "$SRC/libexec/updater.sh" \
  "$SRC/libexec/supervise.sh" \
  "$SRC/libexec/control.sh" \
  "$SRC/libexec/dns.sh" \
  "$SRC/libexec/launch.sh" \
  "$SRC/libexec/a2a" \
  "$SRC/libexec/timezone.sh" \
  "$SRC/action.sh" \
  "$SRC/boot-completed.sh" \
  "$SRC/hotinstall.sh" \
  "$HERE/txn_test.sh"
do
  if [ ! -f "$f" ]; then
    echo "  SKIP（文件不存在）: $f"
    continue
  fi
  if sh -n "$f" 2>/dev/null; then
    echo "  ok   $f"
  else
    echo "  FAIL $f"
    sh -n "$f" 2>&1 | head -5
    FAIL=1
  fi
done

echo
echo "== 2. 事务/DNS/CLI 故障注入测试 =="
# 用与模块一致的 POSIX shell跑；txn_test.sh 自己会隔离在 test/out/txn。
if "$SH_BIN" "$HERE/txn_test.sh"; then
  echo "  ok   txn_test.sh"
else
  echo "  FAIL txn_test.sh"
  FAIL=1
fi

# 可选：Python verify 套件
if [ "${1:-}" = "--full" ]; then
  echo
  echo "== 3. Python verify 套件 =="
  if command -v python >/dev/null 2>&1; then
    PY=python
  elif command -v python3 >/dev/null 2>&1; then
    PY=python3
  else
    PY=""
    echo "  SKIP（未找到 python）"
  fi
  if [ -n "$PY" ]; then
    for v in verify_fixes.py verify_loop.py; do
      if [ -f "$HERE/$v" ]; then
        if "$PY" "$HERE/$v"; then
          echo "  ok   $v"
        else
          echo "  FAIL $v"
          FAIL=1
        fi
      else
        echo "  SKIP（文件不存在）: $v"
      fi
    done
  fi
else
  echo
  echo "（提示：sh test/run.sh --full 可追加 Python verify 套件）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "=== 全部通过 ==="
  exit 0
else
  echo "=== 存在失败 ==="
  exit 1
fi
