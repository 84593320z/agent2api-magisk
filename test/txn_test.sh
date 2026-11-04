#!/bin/sh
# ============================================================================
# 事务与恢复回归测试（配合 v3.4.0 审计修复 F-001..F-005、F-007、F-008）
#
# 设计约束：
#   * 纯 POSIX sh（dash/MSYS sh 可跑），不依赖 bash 扩展；
#   * 被测代码是 module/libexec 下的源码原文（common/payload/updater/dns
#     整文件 source，a2a 只切 cmd_ensure_payload 函数），只 stub 操作系统
#     边界（进程存活、服务控制、时间无关的 dumpsys 采样）；
#   * 所有写入都落在 $WORK 指定的隔离目录，绝不触碰 /data；
#   * 中断注入用子 shell 里覆盖 mv/cp + exit，模拟"两次 rename 之间被杀"。
#
# 用法：sh test/txn_test.sh [工作目录]     # 默认 test/out/txn
# 退出码：0=全部通过，1=存在失败。
# ============================================================================
set -u

SRC=$(cd "$(dirname "$0")/../module" && pwd)
WORK=${1:-$(dirname "$0")/out/txn}
mkdir -p "$WORK" 2>/dev/null || { echo "无法创建工作目录 $WORK" >&2; exit 1; }

PASS=0; FAIL=0; FAILED_NAMES=""

# ---------------------------------------------------------------------------
# 断言助手
# ---------------------------------------------------------------------------
ck() { # $1=名称 $2=期望 $3=实际
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $1"
    printf '  FAIL %s  期望[%s] 实际[%s]\n' "$1" "$2" "$3"
  fi
}
ckf() { # $1=名称 $2=文件存在(1)/不存在(0)
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "1" ] && [ -e "$3" ]; then _r=1
  elif [ "$2" = "0" ] && [ ! -e "$3" ]; then _r=1
  else _r=0; fi
  if [ "$_r" = "1" ]; then
    PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); FAILED_NAMES="$FAILED_NAMES $1"
    printf '  FAIL %s  期望存在=%s 实际路径=%s\n' "$1" "$2" "$3"
  fi
}
TOTAL=0

hdr() { printf '\n== %s ==\n' "$1"; }

# ---------------------------------------------------------------------------
# 载入源码原文（stub 在 source 之后定义，覆盖同名函数）
# ---------------------------------------------------------------------------
MODDIR="$SRC"
# shellcheck disable=SC1091
. "$MODDIR/libexec/common.sh"
# shellcheck disable=SC1091
. "$MODDIR/libexec/payload.sh"
# shellcheck disable=SC1091
. "$MODDIR/libexec/updater.sh"
# shellcheck disable=SC1091
. "$MODDIR/libexec/dns.sh"

# ---- OS / 进程边界 stub ----------------------------------------------------
proc_start_ticks() { printf '12345'; }
pid_alive() { [ "$1" = "$$" ]; }
space_require_kb() { return 0; }
live_link_refresh() { return 0; }
# 服务控制：状态落文件（崩溃注入/事务都在子 shell 里跑，跨边界可断言）
# RUN=0/1 写在 $RUNDIR/svc.run，RESTARTED 写在 $RUNDIR/svc.restarted，
# SVC_STOPS 计数写在 $RUNDIR/svc.stops。
SVC_STOP_MODE=all_ok
svc_run_set() { printf '%s' "$1" >"$RUNDIR/svc.run"; }
svc_run_get() { cat "$RUNDIR/svc.run" 2>/dev/null || echo 0; }
svc_restart_mark() { printf '1' >"$RUNDIR/svc.restarted"; }
svc_is_running() { [ "$(svc_run_get)" = "1" ]; }
svc_stop() {
  _n=$(($(cat "$RUNDIR/svc.stops" 2>/dev/null || echo 0) + 1))
  printf '%s' "$_n" >"$RUNDIR/svc.stops"
  if [ "$SVC_STOP_MODE" = "first_only" ] && [ "$_n" -gt 1 ]; then
    printf 'SVC_STOP_REFUSED n=%s\n' "$_n" >>"$EVENTS"
    return 1
  fi
  svc_run_set 0
  printf 'SVC_STOP n=%s\n' "$_n" >>"$EVENTS"
}
svc_kill_stray() { :; }
svc_stray_pids() { :; }
svc_start() {
  svc_run_set 1
  printf 'SVC_START\n' >>"$EVENTS"
  # 模拟新版服务启动后立即写自己的新 schema（正是 F-001 要防的污染窗口）
  printf 'new-schema' >"$DATADIR/agent2api.db" 2>/dev/null
}
svc_restart() { svc_run_set 1; svc_restart_mark; printf 'SVC_RESTART\n' >>"$EVENTS"; }
svc_wait_health() { [ -f "$RUNDIR/svc.restarted" ]; }
svc_server_pid() { :; }

# ---------------------------------------------------------------------------
# 每个用例重置环境：所有顶层派生路径都要跟着 RUNDIR 走
# ---------------------------------------------------------------------------
reset_case() { # $1=用例名
  CASE_NAME=$1
  APP_HOME="$WORK/cases/$1"
  case "$APP_HOME" in "$WORK"/cases/*) rm -rf "$APP_HOME" ;; *) echo "bad path" >&2; exit 99 ;; esac
  PAYLOAD="$APP_HOME/payload"; PLIB="$PAYLOAD/lib"
  DATADIR="$APP_HOME/data"; BACKUPDIR="$APP_HOME/backup"; RUNDIR="$APP_HOME/run"
  TMPD="$APP_HOME/tmp"; BINDIR="$APP_HOME/bin"; LOGDIR="$APP_HOME/logs"; CFGDIR="$APP_HOME/etc"
  HOMEDIR="$APP_HOME/home"; DLDIR="$APP_HOME/download"
  SETTINGS="$CFGDIR/settings.conf"
  SUPLOG="$LOGDIR/supervisor.log"; SRVLOG="$LOGDIR/server.log"; APPLOG="$LOGDIR/app.log"
  UPDLOG="$LOGDIR/update.log"; INSTLOG="$LOGDIR/install.log"
  SERVER_BIN="$PAYLOAD/agent2api-server"; LOADER="$PLIB/ld-linux-aarch64.so.1"
  A2A_LIVE="$APP_HOME/live"; DNSFILE="$A2A_LIVE/resolv"
  GAIFILE="$A2A_LIVE/gai"; NSSFILE="$A2A_LIVE/nsswitch"; LDSO_LINK="$A2A_LIVE/ld.so"
  DNS_CACHE="$RUNDIR/resolv.last"
  DNS_ACTIVE_CACHE="$RUNDIR/dns-active"; DNS_VPN_CACHE="$RUNDIR/dns-vpn"; DNS_NETID_CACHE="$RUNDIR/dns-netid"
  UPD_LOCK="$RUNDIR/update.lock.d"; UPD_ACTIVE="$RUNDIR/update.active"
  A2A_TXN_JOURNAL="$RUNDIR/update.journal"
  EVENTS="$WORK/cases/$1/events.txt"
  mkdir -p "$DATADIR" "$BACKUPDIR" "$RUNDIR" "$TMPD" "$LOGDIR" "$CFGDIR" "$A2A_LIVE" "$BINDIR" "$HOMEDIR" "$DLDIR"
  : >"$SETTINGS"; : >"$EVENTS"
  # 事务/updater 状态清零
  PAYLOAD_TXID=""; TXN_TAG=""; TXN_OLD_PAYLOAD=""; TXN_DATA_SNAP=0
  TXN_DATA_TMP=""; TXN_DATA_ASIDE=""; TXN_NEW_BUILT=""
  PAYLOAD_DATA_SNAPSHOT_TAKEN=0
  UPDATE_LOCK_TOKEN=""; UPDATE_LOCK_PATH=""
  UPD_TMP=""; UPD_WAS_RUNNING=0; UPD_INSTALLED=0; UPD_ACTIVATE_BEFORE=""
  UPD_ACTIVATE_AFTER=""; UPD_ACTIVE_WRITTEN=0; UPD_LOCK_HELD=0
  UPD_SERVICE_STOPPED=0; UPD_SERVICE_STARTED=0; UPD_DATA_SNAP=0; UPD_COMMITTED=0
  RUN=0; SVC_STOPS=0; SVC_STOP_MODE=all_ok; RESTARTED=0
  rm -f "$RUNDIR/svc.run" "$RUNDIR/svc.stops" "$RUNDIR/svc.restarted"
}

# 造一个最小合法载荷目录（静态 musl 语义：不含 ld-linux 字符串）
seed_payload() { # $1=目录 $2=版本
  mkdir -p "$1/ui"
  {
    printf '\177ELF\002\001\001\000'
    printf '\000\000\000\000\000\000\000\000'
    printf '\002\000\267\000'
    dd if=/dev/urandom bs=1024 count=64 2>/dev/null | tr -d '\000'
  } >"$1/agent2api-server"
  printf 'ver=%s\nbuilt=2026-11-04T00:00:00Z\nsource=local-test\narch=arm64\n' "$2" >"$1/VERSION"
  printf '<html></html>\n' >"$1/ui/index.html"
}
# 造一个动态载荷目录（带 ld-linux 字符串 + lib 运行时）
seed_payload_dyn() { # $1=目录 $2=版本
  seed_payload "$1" "$2"
  printf 'ld-linux-aarch64' >>"$1/agent2api-server"
  mkdir -p "$1/lib"
  printf 'fake-loader\n' >"$1/lib/ld-linux-aarch64.so.1"
  printf 'fake-libc\n' >"$1/lib/libc.so.6"
}
# 造本地升级包（tar.gz + 同名 .sha256）
make_pkg() { # $1=版本 -> $APP_HOME/local.tar.gz
  _mp="$TMPD/pkgsrc.$$"
  rm -rf "$_mp"; mkdir -p "$_mp/ui"
  {
    printf '\177ELF\002\001\001\000'
    printf '\000\000\000\000\000\000\000\000'
    printf '\002\000\267\000'
    dd if=/dev/urandom bs=1024 count=1100 2>/dev/null | tr -d '\000'
  } >"$_mp/agent2api-server"
  printf '<html></html>\n' >"$_mp/ui/index.html"
  tar -czf "$APP_HOME/local.tar.gz" -C "$_mp" agent2api-server ui 2>/dev/null
  _h=$(sha256sum "$APP_HOME/local.tar.gz" 2>/dev/null | awk '{print $1}')
  printf '%s  agent2api-server-linux-arm64.tar.gz\n' "$_h" >"$APP_HOME/local.tar.gz.sha256"
  rm -rf "$_mp"
}
pver() { sed -n 's/^ver=//p' "$1/VERSION" 2>/dev/null | head -n 1; }
jphase() { awk 'NR==1{print $3; exit}' "$A2A_TXN_JOURNAL" 2>/dev/null; }

# ============================================================================
# T0：journal 基础读写
# ============================================================================
hdr 'T0 journal 读写往返'
reset_case t0
PAYLOAD_TXID="txid-t0"; TXN_TAG="update-stable"
TXN_OLD_PAYLOAD="$APP_HOME/payload.new.old.1"; TXN_NEW_BUILT="2026-11-04T00:00:00Z"
payload_txn_write prepared
ck 'T0 write rc' 0 $?
ck 'T0 phase' prepared "$(payload_txn_phase)"
ck 'T0 txid' txid-t0 "$(payload_txn_field 2)"
ck 'T0 old_payload' "$APP_HOME/payload.new.old.1" "$(payload_txn_field 7)"
ck 'T0 new_built' 2026-11-04T00:00:00Z "$(payload_txn_field 12)"
TXN_TAG=""; TXN_OLD_PAYLOAD=""; TXN_NEW_BUILT=""
payload_txn_reload
ck 'T0 reload tag' update-stable "$TXN_TAG"
ck 'T0 reload old' "$APP_HOME/payload.new.old.1" "$TXN_OLD_PAYLOAD"
ck 'T0 reload built' 2026-11-04T00:00:00Z "$TXN_NEW_BUILT"
payload_txn_clear
ck 'T0 clear rc' 0 $?
ck 'T0 phase after clear' '' "$(payload_txn_phase)"

# ============================================================================
# T1：更新健康失败 -> 先停新版再回滚数据（F-001）
# ============================================================================
hdr 'T1 更新健康失败：回滚数据前新版必须已停止'
reset_case t1
seed_payload "$PAYLOAD" 1.0.0
printf 'old-schema' >"$DATADIR/agent2api.db"
make_pkg 2.0.0
svc_run_set 1
# 子 shell 隔离：失败路径 upd_fail -> upd_on_signal 会 exit 1，
# 只允许杀掉子 shell；磁盘状态（journal/svc 文件/EVENTS）跨边界可断言。
# mv 注入：记录数据目录被移开的瞬间服务是否还活着（F-001 的不变量），
# 服务状态从 svc.run 文件读，不依赖 shell 变量传播。
(
  mv() {
    if [ "${1:-}" = "$DATADIR" ]; then
      printf 'MOVE_DATA_ASIDE run=%s\n' "$(svc_run_get)" >>"$EVENTS"
      [ "$(svc_run_get)" = "1" ] && printf 'BUG_SERVICE_ALIVE_AT_DATA_SWAP\n' >>"$EVENTS"
    fi
    command mv "$@"
  }
  LOCAL_TAG=v2.0.0 upd_do_update stable 1 "$APP_HOME/local.tar.gz" >"$WORK/cases/t1/update.out" 2>&1
)
T1_RC=$?
ck 'T1 更新返回失败' 1 "$T1_RC"
ck 'T1 数据换入时服务已停(无BUG标记)' 0 "$(grep -c BUG_SERVICE_ALIVE_AT_DATA_SWAP "$EVENTS" 2>/dev/null)"
ck 'T1 确实发生了数据回滚' 1 "$(grep -c MOVE_DATA_ASIDE "$EVENTS" 2>/dev/null)"
ck 'T1 数据回到升级前快照' old-schema "$(cat "$DATADIR/agent2api.db" 2>/dev/null)"
ck 'T1 载荷回到 1.0.0' 1.0.0 "$(pver "$PAYLOAD")"
ck 'T1 journal 已收尾' '' "$(jphase)"
ck 'T1 服务已恢复运行' 1 "$(svc_is_running >/dev/null 2>&1 && echo 1 || echo 0)"
sweep_stale_dirs >/dev/null 2>&1
ck 'T1 sweep 后无残留旧载荷目录' 0 "$(find "$APP_HOME" -maxdepth 1 -name 'payload.*old*' 2>/dev/null | wc -l | tr -d ' ')"

# ============================================================================
# T1b：停不下新版 -> rollback-blocked，现场保全等开机（F-001）
# ============================================================================
hdr 'T1b 新版停不下来：rollback-blocked 保全现场'
reset_case t1b
seed_payload "$PAYLOAD" 1.0.0
printf 'old-schema' >"$DATADIR/agent2api.db"
make_pkg 2.0.0
svc_run_set 1; SVC_STOP_MODE=first_only   # 第一次停旧版成功，之后停不下来
(
  LOCAL_TAG=v2.0.0 upd_do_update stable 1 "$APP_HOME/local.tar.gz" >"$WORK/cases/t1b/update.out" 2>&1
)
T1B_RC=$?
ck 'T1b 更新返回失败' 1 "$T1B_RC"
ck 'T1b journal=rollback-blocked' rollback-blocked "$(jphase)"
ck 'T1b 数据未被回滚(仍是新版现场)' new-schema "$(cat "$DATADIR/agent2api.db" 2>/dev/null)"
ck 'T1b 载荷保持新版' 2.0.0 "$(pver "$PAYLOAD")"
ck 'T1b 未发生数据换入' 0 "$(grep -c MOVE_DATA_ASIDE "$EVENTS" 2>/dev/null)"
ck 'T1b 停服被拒有记录' 1 "$(grep -c SVC_STOP_REFUSED "$EVENTS" 2>/dev/null)"
sweep_stale_dirs >/dev/null 2>&1
ck 'T1b sweep 保留 journal 引用的旧载荷' 1 "$(find "$APP_HOME" -maxdepth 1 -name 'payload.new.old.*' 2>/dev/null | wc -l | tr -d ' ')"

# ============================================================================
# T2：切换中崩溃（第一次 rename 后）-> 开机立即恢复（F-002）
# ============================================================================
hdr 'T2 切换中崩溃：开机恢复不受 120s 门槛限制'
reset_case t2
seed_payload "$PAYLOAD" 1.0.0
# 暂存名必须落在 payload.new.* 命名空间（真实 updater 的暂存约定），
# sweep 才能清理无主残留；用任意名会在 APP_HOME 留垃圾。
_STAGED="$APP_HOME/payload.new.4242"
mkdir -p "$_STAGED"
seed_payload "$_STAGED" 2.0.0
(
  mv() {
    if [ "${1:-}" = "$PAYLOAD" ]; then
      command mv "$@"
      exit 77   # 崩溃点：旧载荷已移走、新载荷尚未就位
    fi
    command mv "$@"
  }
  payload_activate_staged "$_STAGED" new >/dev/null 2>&1
)
T2_CRASH=$?
ck 'T2 崩溃注入生效(rc=77)' 77 "$T2_CRASH"
ck 'T2 崩溃后 PAYLOAD 缺失' 0 "$([ -e "$PAYLOAD" ] && echo 1 || echo 0)"
ck 'T2 journal=switching' switching "$(jphase)"
ck 'T2 旧载荷被 journal 记录' 1 "$(find "$APP_HOME" -maxdepth 1 -name 'payload.new.old.*' 2>/dev/null | wc -l | tr -d ' ')"
sleep 1   # 切换标记年龄远小于 120s —— 旧实现会跳过恢复
payload_recover_interrupted boot >"$WORK/cases/t2/recover.out" 2>&1
ck 'T2 开机恢复成功' 0 $?
ck 'T2 载荷恢复 1.0.0' 1.0.0 "$(pver "$PAYLOAD")"
ck 'T2 journal 已清' '' "$(jphase)"
sweep_stale_dirs >/dev/null 2>&1
ck 'T2 无残留切换目录' 0 "$(find "$APP_HOME" -maxdepth 1 \( -name 'payload.*old*' -o -name 'payload.new.*' \) 2>/dev/null | wc -l | tr -d ' ')"
ck 'T2 switching 标记被清' 0 "$([ -f "$RUNDIR/payload.switching" ] && echo 1 || echo 0)"

# ============================================================================
# T3：数据回滚中崩溃（DATADIR 已移开、快照未换入）-> 开机补完（F-003）
# ============================================================================
hdr 'T3 数据回滚中断：开机补完换入，不留空 data'
reset_case t3
seed_payload "$PAYLOAD" 1.0.0
# 升级前快照（属于事务 txid-999）
mkdir -p "$BACKUPDIR/data-prev"
printf 'old-data' >"$BACKUPDIR/data-prev/agent2api.db"
printf 'txid-999 123\n' >"$BACKUPDIR/data-prev.txid"
# 崩溃现场：数据目录已被移开成 aside，快照副本停在 restore 中转名
mkdir -p "$APP_HOME/data.upgraded.999"
printf 'new-data' >"$APP_HOME/data.upgraded.999/agent2api.db"
mkdir -p "$APP_HOME/data.restore.999"
printf 'old-data' >"$APP_HOME/data.restore.999/agent2api.db"
rm -rf "$DATADIR"
printf 'v1 txid-999 rolling-back 424242 12345 update-stable %s 1 %s %s 111 -\n' \
  "$PAYLOAD" "$APP_HOME/data.restore.999" "$APP_HOME/data.upgraded.999" >"$A2A_TXN_JOURNAL"
payload_recover_interrupted boot >"$WORK/cases/t3/recover.out" 2>&1
ck 'T3 开机恢复成功' 0 $?
ck 'T3 data 补完换入(快照内容)' old-data "$(cat "$DATADIR/agent2api.db" 2>/dev/null)"
ck 'T3 journal 已清' '' "$(jphase)"
ck 'T3 无残留中转/移开目录' 0 "$(find "$APP_HOME" -maxdepth 1 -name 'data.restore.*' -o -maxdepth 1 -name 'data.upgraded.*' 2>/dev/null | wc -l | tr -d ' ')"

# ============================================================================
# T4：sweep 不得删除 journal 引用的恢复材料（F-004）
# ============================================================================
hdr 'T4 sweep 保护 journal 引用目录'
reset_case t4
mkdir -p "$APP_HOME/payload.new.old.555"
seed_payload "$APP_HOME/payload.new.old.555" 1.0.0
mkdir -p "$APP_HOME/payload.new.junk"
mkdir -p "$APP_HOME/data.restore.777"
printf 'v1 txid-a switching 555 11111 update-stable %s 0 %s - 111 -\n' \
  "$APP_HOME/payload.new.old.555" "$APP_HOME/data.restore.777" >"$A2A_TXN_JOURNAL"
sweep_stale_dirs >/dev/null 2>&1
ckf 'T4 journal 引用的旧载荷保留' 1 "$APP_HOME/payload.new.old.555"
ckf 'T4 journal 引用的数据中转保留' 1 "$APP_HOME/data.restore.777"
ckf 'T4 无主 payload.new.* 被清' 0 "$APP_HOME/payload.new.junk"
payload_txn_clear
mkdir -p "$APP_HOME/payload.new.junk2" "$APP_HOME/data.restore.888"
sweep_stale_dirs >/dev/null 2>&1
ckf 'T4 无 journal 后无主目录被清(payload)' 0 "$APP_HOME/payload.new.junk2"
ckf 'T4 无 journal 后无主目录被清(data)' 0 "$APP_HOME/data.restore.888"

# ============================================================================
# T5：cmd_ensure_payload 区分静态/动态载荷（F-005）
# ============================================================================
hdr 'T5 静态载荷无 loader 也可启动检查'
reset_case t5
sed -n '/^cmd_ensure_payload() {/,/^}$/p' "$MODDIR/libexec/a2a" >"$WORK/cases/t5/cep.sh"
SAY_OUT="$WORK/cases/t5/say.txt"; : >"$SAY_OUT"
say() { printf '%s\n' "$*" >>"$SAY_OUT"; }
# shellcheck disable=SC1090
. "$WORK/cases/t5/cep.sh"
seed_payload "$PAYLOAD" 1.0.0
ckf 'T5 静态载荷无 lib/ld-linux' 0 "$LOADER"
cmd_ensure_payload >/dev/null 2>&1
ck 'T5 静态载荷通过' 0 $?
rm -rf "$PAYLOAD"
seed_payload_dyn "$PAYLOAD" 1.0.0
chmod 644 "$LOADER"
cmd_ensure_payload >/dev/null 2>&1
ck 'T5 动态载荷 loader 不可执行被拒' 1 $?
ck 'T5 提示动态链接器缺失' 1 "$(grep -c '动态链接器缺失' "$SAY_OUT" 2>/dev/null)"
# chmod 在 MSYS(noacl) 挂载上不改变 -x 判定；符号链接指向真实可执行
# 文件在 Linux 与 MSYS 上都成立，两种环境测的都是同一件事。
rm -f "$LOADER"
ln -sf "$(command -v sh)" "$LOADER"
cmd_ensure_payload >/dev/null 2>&1
ck 'T5 动态载荷 loader 可执行通过' 0 $?
rm -f "$SERVER_BIN"
cmd_ensure_payload >/dev/null 2>&1
ck 'T5 服务端缺失被拒' 1 $?
ck 'T5 提示载荷缺失' 1 "$(grep -c '载荷缺失' "$SAY_OUT" 2>/dev/null)"

# ============================================================================
# T6：网络变化后必须重算 DNS，不再信旧解析器验活（F-007）
# ============================================================================
hdr 'T6 网络变化重算 DNS'
reset_case t6
printf 'dns_mode=auto\n' >"$SETTINGS"
printf 'wlan0' >"$DNS_ACTIVE_CACHE"; printf '0' >"$DNS_VPN_CACHE"; printf '100' >"$DNS_NETID_CACHE"
DNS_ENSURE=0
dns_default_iface() { echo tun0; }
dns_vpn_active() { return 0; }
dns_active_netid() { echo 101; }
dns_liveness_ok() { return 0; }   # 旧 DNS 仍可达 —— 旧实现会就此止步
dns_ensure() { DNS_ENSURE=$((DNS_ENSURE + 1)); }
dns_refresh_if_changed >/dev/null 2>&1
ck 'T6 网络变化触发重算' 1 "$DNS_ENSURE"
# 网络未变化 + 验活通过 -> 不重算
printf 'tun0' >"$DNS_ACTIVE_CACHE"; printf '1' >"$DNS_VPN_CACHE"; printf '101' >"$DNS_NETID_CACHE"
DNS_ENSURE=0
dns_refresh_if_changed >/dev/null 2>&1
ck 'T6 网络未变化不重算' 0 "$DNS_ENSURE"

# ============================================================================
# T7：采样失败但缓存有效 -> 恢复 live 文件（F-008）
# ============================================================================
hdr 'T7 DNS 缓存恢复 live 文件'
reset_case t7
printf 'dns_mode=auto\n' >"$SETTINGS"
printf 'nameserver 9.9.9.9\n' >"$DNS_CACHE"
dns_default_iface() { :; }
dns_collect_system() { return 1; }   # 采样失败
dns_write auto >/dev/null 2>&1
ck 'T7 返回成功' 0 $?
ck 'T7 live 文件已恢复' 1 "$(grep -c 'nameserver 9.9.9.9' "$DNSFILE" 2>/dev/null)"
ck 'T7 缓存保留' 9.9.9.9 "$(awk '/^nameserver/{print $2; exit}' "$DNS_CACHE" 2>/dev/null)"
# 无缓存 -> 静态兜底
rm -f "$DNSFILE" "$DNS_CACHE"
dns_write auto >/dev/null 2>&1
ck 'T7 无缓存走静态兜底' 1 "$(grep -c 'nameserver 223.5.5.5' "$DNSFILE" 2>/dev/null)"

# ============================================================================
printf '\n=== %d checked / %d passed / %d failed ===\n' "$TOTAL" "$PASS" "$FAIL"
[ -n "$FAILED_NAMES" ] && printf 'failed:%s\n' "$FAILED_NAMES"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
