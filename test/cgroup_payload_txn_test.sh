#!/bin/sh
# cgroup mountinfo 顺序与运行库 rename 故障的独立回归；不需要 Android/root。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK=${1:-"$HERE/out/cgroup-payload-txn"}
rm -rf "$WORK"
mkdir -p "$WORK" || exit 1

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then ok "$3"; else
    fail "$3 (expected=[$2] actual=[$1])"
  fi
}
assert_file() { [ -f "$1" ] && ok "$2" || fail "$2 (missing $1)"; }
assert_absent() { [ ! -e "$1" ] && ok "$2" || fail "$2 (unexpected $1)"; }

# 执行从生产 common.sh 原样提取的 awk，而不是在测试里复制一份实现。
awk '
  /_cge_mnt=\$\(awk -v want=/ { in_block = 1 }
  in_block { print }
  in_block && /\/proc\/self\/mountinfo/ { exit }
' "$ROOT/module/libexec/common.sh" >"$WORK/cgroup.raw"
sed 's|/proc/self/mountinfo|"$_A2A_TEST_MOUNTINFO"|' \
  "$WORK/cgroup.raw" >"$WORK/cgroup.snippet"
[ -s "$WORK/cgroup.snippet" ] || { echo '无法提取 cgroup awk' >&2; exit 1; }

cgroup_mount() {
  _cge_want=$1
  _A2A_TEST_MOUNTINFO=$2
  . "$WORK/cgroup.snippet"
  printf '%s' "$_cge_mnt"
}

printf '%s\n' \
  '10 1 0:1 /subtree /fallback rw - cgroup2 none rw' \
  '11 1 0:1 / /root rw - cgroup2 none rw' >"$WORK/fallback-first"
assert_eq "$(cgroup_mount cgroup2 "$WORK/fallback-first")" '/root' \
  'cgroup2 fallback-before-root returns only root mount'
assert_eq "$(cgroup_mount cgroup2 "$WORK/fallback-first" | awk '{ n++ } END { print n + 0 }')" '1' \
  'cgroup2 root result has exactly one line'

printf '%s\n' \
  '11 1 0:1 / /root rw - cgroup2 none rw' \
  '10 1 0:1 /subtree /fallback rw - cgroup2 none rw' >"$WORK/root-first"
assert_eq "$(cgroup_mount cgroup2 "$WORK/root-first")" '/root' \
  'cgroup2 root-before-fallback keeps root priority'
printf '%s\n' \
  '10 1 0:1 /one /first rw - cgroup2 none rw' \
  '11 1 0:1 /two /second rw - cgroup2 none rw' >"$WORK/fallback-only"
assert_eq "$(cgroup_mount cgroup2 "$WORK/fallback-only")" '/first' \
  'cgroup2 non-root-only keeps first fallback'
printf '%s\n' '10 1 0:1 / /other rw - cgroup none rw' >"$WORK/no-match"
assert_eq "$(cgroup_mount cgroup2 "$WORK/no-match")" '' \
  'cgroup2 no-match stays empty'
printf '%s\n' \
  '10 1 0:1 /subtree /cpu-fallback rw - cgroup none rw,cpu' \
  '11 1 0:1 / /cpu-root rw - cgroup none rw,cpu' >"$WORK/cpu-order"
assert_eq "$(cgroup_mount cpu "$WORK/cpu-order")" '/cpu-root' \
  'cgroup v1 fallback-before-root returns only root mount'

# source 真实 payload.sh；只替换权限、loader 自检和 live-link OS 边界。
RUNDIR="$WORK/run"
mkdir -p "$RUNDIR"
# shellcheck disable=SC1091
. "$ROOT/module/libexec/payload.sh"
payload_fix_perms() { :; }
live_link_refresh() { :; }
VERIFY_MODE=ok
lib_verify() { [ "$VERIFY_MODE" = ok ]; }
MV_MODE=none
mv() {
  if [ "$MV_MODE" = snapshot-old ] && [ "$1" = "$BACKUPDIR/lib" ] && [ "$2" = "$BACKUPDIR/lib.old" ]; then
    return 1
  fi
  if [ "$MV_MODE" = snapshot-new ] && [ "$1" = "$BACKUPDIR/lib.new" ] && [ "$2" = "$BACKUPDIR/lib" ]; then
    return 1
  fi
  if [ "$MV_MODE" = restore-old ] && [ "$1" = "$PLIB" ] && [ "$2" = "$PLIB.bad" ]; then
    return 1
  fi
  if [ "$MV_MODE" = restore-new ] && [ "$1" = "$PLIB.restore" ] && [ "$2" = "$PLIB" ]; then
    return 1
  fi
  if [ "$MV_MODE" = restore-rollback ] && [ "$1" = "$PLIB.bad" ] && [ "$2" = "$PLIB" ]; then
    return 1
  fi
  command mv "$@"
}

setup_snapshot() {
  CASE="$WORK/$1"
  rm -rf "$CASE"
  PLIB="$CASE/live/lib"
  BACKUPDIR="$CASE/backup"
  PAYLOAD="$CASE/payload"
  mkdir -p "$PLIB" "$BACKUPDIR/lib" "$PAYLOAD"
  printf 'live\n' >"$PLIB/loader"
  printf 'old-snapshot\n' >"$BACKUPDIR/lib/loader"
  MV_MODE=none
  VERIFY_MODE=ok
}

snapshot_fault() {
  setup_snapshot "$1"
  MV_MODE="$2"
  lib_snapshot_save >/dev/null 2>&1
  rc=$?
  MV_MODE=none
  if [ "$rc" -ne 0 ]; then ok "$1 returns nonzero"; else fail "$1 returned success"; fi
  assert_eq "$(cat "$BACKUPDIR/lib/loader" 2>/dev/null)" 'old-snapshot' \
    "$1 preserves previous snapshot"
  assert_absent "$BACKUPDIR/lib/lib.new" "$1 does not nest staging in old snapshot"
  assert_absent "$BACKUPDIR/lib.old" "$1 leaves no old rotation artifact"
}
snapshot_fault snapshot-first-rename snapshot-old
assert_absent "$BACKUPDIR/lib.new" 'snapshot first rename removes staging'
snapshot_fault snapshot-second-rename snapshot-new

setup_snapshot snapshot-success
lib_snapshot_save >/dev/null 2>&1
assert_eq "$?" '0' 'snapshot success returns zero'
assert_eq "$(cat "$BACKUPDIR/lib/loader")" 'live' 'snapshot success publishes new copy'
assert_absent "$BACKUPDIR/lib.old" 'snapshot success removes rotation backup'
assert_absent "$BACKUPDIR/lib.new" 'snapshot success removes staging'

setup_restore() {
  setup_snapshot "$1"
  rm -rf "$BACKUPDIR/lib"
  mkdir -p "$BACKUPDIR/lib"
  printf 'backup\n' >"$BACKUPDIR/lib/loader"
}

restore_fault() {
  setup_restore "$1"
  MV_MODE="$2"
  lib_restore >/dev/null 2>&1
  rc=$?
  MV_MODE=none
  if [ "$rc" -ne 0 ]; then ok "$1 returns nonzero"; else fail "$1 returned success"; fi
  assert_eq "$(cat "$PLIB/loader" 2>/dev/null)" 'live' \
    "$1 preserves or restores current loader"
  assert_absent "$PLIB/lib.restore" "$1 does not nest restore in current loader"
  assert_absent "$PLIB.bad" "$1 leaves no bad rotation artifact"
}
restore_fault restore-first-rename restore-old
assert_absent "$PLIB.restore" 'restore first rename removes staging'
restore_fault restore-second-rename restore-new

setup_restore restore-rollback-failure
MV_MODE=restore-new
# 第一次 restore-new 失败后，让 bad -> PLIB 的恢复也失败。
mv() {
  if [ "$1" = "$PLIB.restore" ] && [ "$2" = "$PLIB" ]; then return 1; fi
  if [ "$1" = "$PLIB.bad" ] && [ "$2" = "$PLIB" ]; then return 1; fi
  command mv "$@"
}
lib_restore >/dev/null 2>&1
rc=$?
# 恢复下面的通用注入器。
MV_MODE=none
mv() {
  if [ "$MV_MODE" = snapshot-old ] && [ "$1" = "$BACKUPDIR/lib" ] && [ "$2" = "$BACKUPDIR/lib.old" ]; then return 1; fi
  if [ "$MV_MODE" = snapshot-new ] && [ "$1" = "$BACKUPDIR/lib.new" ] && [ "$2" = "$BACKUPDIR/lib" ]; then return 1; fi
  if [ "$MV_MODE" = restore-old ] && [ "$1" = "$PLIB" ] && [ "$2" = "$PLIB.bad" ]; then return 1; fi
  if [ "$MV_MODE" = restore-new ] && [ "$1" = "$PLIB.restore" ] && [ "$2" = "$PLIB" ]; then return 1; fi
  if [ "$MV_MODE" = restore-rollback ] && [ "$1" = "$PLIB.bad" ] && [ "$2" = "$PLIB" ]; then return 1; fi
  command mv "$@"
}
[ "$rc" -ne 0 ] && ok 'restore rollback failure returns nonzero' || fail 'restore rollback failure returned success'
assert_file "$PLIB.bad/loader" 'restore rollback failure preserves old loader backup'
assert_absent "$PLIB/lib.restore" 'restore rollback failure does not nest staging'

setup_restore restore-verify-failure
VERIFY_MODE=fail
lib_restore >/dev/null 2>&1
rc=$?
VERIFY_MODE=ok
[ "$rc" -ne 0 ] && ok 'restore validation failure returns nonzero' || fail 'restore validation failure returned success'
assert_eq "$(cat "$PLIB/loader")" 'live' 'restore validation failure rolls back current loader'
assert_absent "$PLIB.bad" 'restore validation rollback removes bad artifact'

setup_restore restore-success
lib_restore >/dev/null 2>&1
assert_eq "$?" '0' 'restore success returns zero'
assert_eq "$(cat "$PLIB/loader")" 'backup' 'restore success publishes backup loader'
assert_absent "$PLIB.bad" 'restore success removes bad artifact'
assert_absent "$PLIB.restore" 'restore success removes staging'

printf '\ncgroup/payload transaction tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
