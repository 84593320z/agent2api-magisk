#!/bin/sh
# update-binary 自解包 fallback 的同父目录事务回归；使用本地假根，不访问手机。
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
WORK=${1:-"$HERE/out/fallback-txn"}
UPDATE="$ROOT/module/META-INF/com/google/android/update-binary"
rm -rf "$WORK"
mkdir -p "$WORK/bin" || exit 1

real_tool() {
  for candidate in "/usr/bin/$1" "/bin/$1"; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  command -v "$1"
}
REAL_CP=$(real_tool cp)
REAL_MV=$(real_tool mv)
REAL_RM=$(real_tool rm)
REAL_MKDIR=$(real_tool mkdir)
export REAL_CP REAL_MV REAL_RM REAL_MKDIR

# standalone busybox 缺陷模拟：所有绝对路径的 mkdir -p 都失败；不带 -p 正常。
cat >"$WORK/bin/mkdir" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -p ]; then
  case "${2:-}" in /*) exit 1 ;; esac
fi
exec "$REAL_MKDIR" "$@"
EOF
cat >"$WORK/bin/unzip" <<'EOF'
#!/bin/sh
# 生产调用：unzip -o ZIP -d DEST
"$REAL_MKDIR" -p "$4" || "$REAL_MKDIR" "$4" || exit 1
"$REAL_CP" -R "$A2A_TEST_MODULE_SRC/." "$4/"
EOF
cat >"$WORK/bin/cp" <<'EOF'
#!/bin/sh
if [ "${A2A_TEST_FAIL_MODE:-}" = copy ]; then
  for arg in "$@"; do
    case "$arg" in *agent2api_install.*) exit 1 ;; esac
  done
fi
exec "$REAL_CP" "$@"
EOF
cat >"$WORK/bin/mv" <<'EOF'
#!/bin/sh
mode=${A2A_TEST_FAIL_MODE:-}
src=${1:-}
dst=${2:-}
case "$src" in "$A2A_TEST_MODPATH".new.*) is_stage=1 ;; *) is_stage=0 ;; esac
case "$src" in "$A2A_TEST_MODPATH".old.*) is_old=1 ;; *) is_old=0 ;; esac
if [ "$mode" = old-rename ] && [ "$src" = "$A2A_TEST_MODPATH" ]; then exit 1; fi
if [ "$mode" = activate-rename ] && [ "$is_stage" = 1 ] && [ "$dst" = "$A2A_TEST_MODPATH" ]; then exit 1; fi
if [ "$mode" = post-activate-invalid-rollback-fail ] && [ "$is_old" = 1 ] && [ "$dst" = "$A2A_TEST_MODPATH" ]; then exit 1; fi
if { [ "$mode" = post-activate-invalid ] || [ "$mode" = post-activate-invalid-rollback-fail ]; } \
   && [ "$is_stage" = 1 ] && [ "$dst" = "$A2A_TEST_MODPATH" ]; then
  "$REAL_MV" "$@" || exit $?
  "$REAL_RM" -f "$dst/module.prop"
  exit 0
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$WORK/bin/"* || exit 1

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert_eq() {
  if [ "$1" = "$2" ]; then ok "$3"; else fail "$3 (expected=[$2] actual=[$1])"; fi
}
assert_absent() { [ ! -e "$1" ] && ok "$2" || fail "$2 (unexpected $1)"; }
assert_file() { [ -f "$1" ] && ok "$2" || fail "$2 (missing $1)"; }
assert_no_artifacts() {
  bad=''
  for p in "$MODPATH".new.* "$MODPATH".old.* "$MODPATH".failed.* \
           "$ROOTFS/data/local/tmp/agent2api_install."*; do
    [ ! -e "$p" ] || bad="$bad $p"
  done
  if [ -z "$bad" ]; then ok "$1 leaves no transaction artifacts"; else fail "$1 artifacts:$bad"; fi
}
assert_old_restored() {
  assert_eq "$(cat "$MODPATH/old-only" 2>/dev/null)" 'old' "$1 restores old module"
  assert_absent "$MODPATH/new-only" "$1 does not retain partial new module"
}

run_install() { # name initial(old|fresh) failure-mode customize(ok|fail)
  CASE="$WORK/$1"
  ROOTFS="$CASE/rootfs"
  MODULE_SRC="$CASE/unpacked"
  MODPATH="$ROOTFS/data/adb/modules_update/agent2api"
  rm -rf "$CASE"
  mkdir -p "$MODULE_SRC/libexec" "$ROOTFS/data/local/tmp"
  cp "$ROOT/module/libexec/mkdir.sh" "$MODULE_SRC/libexec/mkdir.sh"
  printf 'id=agent2api\nversionName=test\n' >"$MODULE_SRC/module.prop"
  printf 'new\n' >"$MODULE_SRC/new-only"
  cat >"$MODULE_SRC/customize.sh" <<'EOF'
#!/sbin/sh
printf '%s' "$MODPATH" >"$A2A_TEST_ROOTFS/customize.modpath"
printf 'customized\n' >"$MODPATH/customized"
[ "${A2A_TEST_CUSTOMIZE_FAIL:-0}" != 1 ] || exit 1
EOF
  if [ "$2" = old ]; then
    mkdir -p "$MODPATH"
    printf 'old\n' >"$MODPATH/old-only"
    printf 'id=agent2api\nversionName=old\n' >"$MODPATH/module.prop"
  fi
  sed -e "s|/data/local/tmp|$ROOTFS/data/local/tmp|g" \
      -e "s|/data/adb/modules_update|$ROOTFS/data/adb/modules_update|g" \
      "$UPDATE" >"$CASE/update-binary"
  customize_fail=0
  [ "$4" = fail ] && customize_fail=1
  # 在子 shell 内部重排 PATH；Windows 测试宿主会为“启动时 PATH=... sh”
  # 再 prepend 自己的 winuxcmd，导致 cp/mv 故障注入被系统命令绕过。
  {
    printf 'PATH="%s":/usr/bin:/bin\nexport PATH\n' "$WORK/bin"
    # winuxcmd 把 cp 实现为内建 emulation，会忽略同名 PATH 脚本；shell 函数
    # 在 Linux 与 Windows 测试宿主上都能可靠注入复制失败。
    cat <<'EOF'
cp() {
  if [ "${A2A_TEST_FAIL_MODE:-}" = copy ]; then
    for arg in "$@"; do
      case "$arg" in *agent2api_install.*) return 1 ;; esac
    done
  fi
  "$REAL_CP" "$@"
}
EOF
    cat "$CASE/update-binary"
  } >"$CASE/run-update"
  A2A_TEST_MODULE_SRC="$MODULE_SRC" \
    A2A_TEST_ROOTFS="$ROOTFS" \
    A2A_TEST_MODPATH="$MODPATH" \
    A2A_TEST_FAIL_MODE="$3" \
    A2A_TEST_CUSTOMIZE_FAIL="$customize_fail" \
    sh "$CASE/run-update" 1 1 "$CASE/dummy.zip" >"$CASE/log" 2>&1
  RC=$?
}

run_install success old none ok
assert_eq "$RC" '0' 'staged install succeeds'
assert_file "$MODPATH/new-only" 'success publishes staged new module'
assert_file "$MODPATH/customized" 'success retains customize output'
assert_absent "$MODPATH/old-only" 'success replaces previous module'
case "$(cat "$ROOTFS/customize.modpath" 2>/dev/null)" in
  "$MODPATH".new.*) ok 'customize runs in same-parent staging directory' ;;
  *) fail 'customize did not run in same-parent staging directory' ;;
esac
assert_no_artifacts success

run_install customize-failure old none fail
[ "$RC" -ne 0 ] && ok 'customize failure returns nonzero' || fail 'customize failure returned success'
assert_old_restored customize-failure
assert_no_artifacts customize-failure

run_install copy-failure old copy ok
[ "$RC" -ne 0 ] && ok 'copy failure returns nonzero' || fail 'copy failure returned success'
assert_old_restored copy-failure
assert_no_artifacts copy-failure

run_install old-rename-failure old old-rename ok
[ "$RC" -ne 0 ] && ok 'old-directory rename failure returns nonzero' || fail 'old-directory rename failure returned success'
assert_old_restored old-rename-failure
assert_no_artifacts old-rename-failure

run_install activation-failure old activate-rename ok
[ "$RC" -ne 0 ] && ok 'activation rename failure returns nonzero' || fail 'activation rename failure returned success'
assert_old_restored activation-failure
assert_no_artifacts activation-failure

run_install post-activation-validation old post-activate-invalid ok
[ "$RC" -ne 0 ] && ok 'post-activation validation failure returns nonzero' || fail 'post-activation validation failure returned success'
assert_old_restored post-activation-validation
assert_no_artifacts post-activation-validation

run_install rollback-failure old post-activate-invalid-rollback-fail ok
[ "$RC" -ne 0 ] && ok 'rollback rename failure returns nonzero' || fail 'rollback rename failure returned success'
# $$ 在测试与安装进程不同，按模式寻找备份并确认旧目录未被删除或嵌套。
old_backup=''
for p in "$MODPATH".old.*; do [ ! -d "$p" ] || old_backup=$p; done
if [ -n "$old_backup" ] && [ "$(cat "$old_backup/old-only" 2>/dev/null)" = old ]; then
  ok 'rollback failure preserves old-directory backup for recovery'
else
  fail 'rollback failure lost old-directory backup'
fi

run_install fresh-post-activation-failure fresh post-activate-invalid ok
[ "$RC" -ne 0 ] && ok 'fresh post-activation failure returns nonzero' || fail 'fresh post-activation failure returned success'
assert_absent "$MODPATH" 'fresh post-activation failure removes partial module'
assert_no_artifacts fresh-post-activation-failure

# 主管理器路径仍必须是 install_module 直转，不得被 fallback 事务代码替换。
main_path=$(sed -n '42,62p' "$UPDATE")
case "$main_path" in *install_module*) ok 'standard install_module path remains present' ;; *) fail 'standard install_module path missing' ;; esac
case "$main_path" in *MODPATH.new*|*MODPATH.old*) fail 'fallback transaction leaked into standard path' ;; *) ok 'fallback transaction is isolated from standard path' ;; esac

printf '\nfallback transaction tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
