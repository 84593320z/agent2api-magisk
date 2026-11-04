#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · boot-worker.sh（开机流程的唯一执行者，独占锁串行）
#
# 背景：service.sh（late_start）与 boot-completed.sh（KSU / APatch 的
# sys.boot_completed 钩子）是两个独立入口，以前各自为政 —— 后者在钩子里
# 直接做 DNS 初始化并 svc_start，绕过了 boot_delay / 网络等待；两个入口
# 还可能并行准备 DNS、并行拉起服务。现在两个入口都只负责“把本脚本丢到
# 后台”，完整流程统一在这里执行：
#     等待 boot_completed → boot_delay → 等待网络 → DNS 三件套 → 插件
#     解释器修复 → 重读 autostart → 决定是否 svc_start。
#
# 锁：$RUNDIR/boot.lock.d（沿用 payload.sh 的 update_lock_* 目录锁）。
#   - 全机同一时刻只跑一份 worker；等待 boot_delay / 网络的整个期间都
#     持有锁，后到的入口投递的 worker 拿不到锁 → 记日志并退出 0（不是
#     错误，也不重试 —— 下一个钩子 / 下次开机自然会再投递）。
#   - worker 被杀或设备重启时锁自然变 stale，update_lock_acquire 自带
#     僵死回收，不会永久卡死。
#
# 进程身份：本脚本由入口以 setsid + 后台方式拉起，$$ 是自己的 PID，
#   update_lock_acquire 读 /proc/$$/stat 的启动代次才能成立 —— 绝不能把
#   这段逻辑写进入口脚本的 `( ... ) &` 子 shell（详见 service.sh 头部）。
#
# $1 = 投递来源标签（service.sh / boot-completed.sh），只用于日志。
# ============================================================================

_self="${0:-}"
case "$_self" in
  */*) MODDIR="${_self%/*}" ;;
  *)   MODDIR="." ;;
esac
# 本脚本住在 <模块根>/libexec/ 下，取目录只得到 libexec，模块根在上一层；
# 先向上找一级，再退标准路径（与 boot-start.sh 的 R19 同一套逻辑）。
if [ ! -f "$MODDIR/module.prop" ]; then
  _bw_parent="${MODDIR%/*}"
  if [ -n "$_bw_parent" ] && [ "$_bw_parent" != "$MODDIR" ]; then
    MODDIR="$_bw_parent"
  fi
fi
[ -f "$MODDIR/module.prop" ] || MODDIR="/data/adb/modules/agent2api"

[ -f "$MODDIR/libexec/common.sh" ] || exit 0
. "$MODDIR/libexec/common.sh"
. "$MODDIR/libexec/control.sh"

BOOTLOG="$LOGDIR/boot.log"
BOOT_LOCK="$RUNDIR/boot.lock.d"

# 来源标签只进日志，收掉一切可能破坏日志格式的字符。
_bw_from="${1:-unknown}"
case "$_bw_from" in
  ''|*[!A-Za-z0-9._-]*) _bw_from="unknown" ;;
esac

log_to "$BOOTLOG" "boot-worker 启动（pid=$$，from=$_bw_from）"

# 独占锁：拿不到 = 已有一份 worker 在跑（或锁出了问题），都不算错误。
# update_lock_acquire 的提示文案是给安装场景写的，这里静默后换成 boot 语境。
if ! update_lock_acquire "$BOOT_LOCK" 5 >/dev/null 2>&1; then
  _bw_seen=$(cat "$BOOT_LOCK/owner" 2>/dev/null)
  _bw_opid=$(printf '%s\n' "$_bw_seen" | awk '{print $1}')
  _bw_ostart=$(printf '%s\n' "$_bw_seen" | awk '{print $2}')
  if [ -n "$_bw_opid" ] && [ -n "$_bw_ostart" ] \
     && pid_alive "$_bw_opid" \
     && [ "$(proc_start_ticks "$_bw_opid" 2>/dev/null)" = "$_bw_ostart" ]; then
    log_to "$BOOTLOG" "boot-worker：已有实例持锁运行（pid=$_bw_opid），本次投递退出"
  else
    log_to "$BOOTLOG" "boot-worker：无法取得 $BOOT_LOCK（owner=${_bw_opid:-无}），放弃本次流程"
  fi
  exit 0
fi

# 出口统一收尾：释放锁 + 轮转日志。信号先转成 exit，让 EXIT trap 兜底，
# 避免被杀时留下 live owner（真留下了也会被下一个实例按 stale 回收）。
boot_worker_finish() {
  update_lock_release "$BOOT_LOCK" 2>/dev/null
  rotate_log "$BOOTLOG" 256 2>/dev/null
}
trap 'exit 1' HUP INT TERM
trap 'boot_worker_finish' EXIT

log_to "$BOOTLOG" "boot-worker：已持有 $BOOT_LOCK，开始开机流程"
ensure_layout

wait_boot_completed 180

_delay=$(cfg_get boot_delay 8)
case "$_delay" in ''|*[!0-9]*) _delay=8 ;; esac
[ "$_delay" -gt 0 ] && sleep "$_delay"

_nw=$(cfg_get net_wait 45)
case "$_nw" in ''|*[!0-9]*) _nw=45 ;; esac
# 等网络超时不是错误（Android 上 net_ready 会因路由表形态误判），但必须留痕迹，
# 否则用户只看到“开机 45 秒后才起来”却查不到原因。
if ! wait_net "$_nw"; then
  log_to "$BOOTLOG" "等待网络超时（${_nw}s），按无网继续启动；DNS 交给分级兜底"
fi

# DNS：这时候系统 DNS 才是真的（boot_completed 之前 ConnectivityService
# 还没把 DnsAddresses 填进去）
. "$MODDIR/libexec/dns.sh"
dns_ensure
nss_apply
gai_apply

# 插件解释器修复（面板拉起的插件二进制）
. "$MODDIR/libexec/plugin.sh"
plugin_interp_fix

# autostart 可能在这几十秒里被用户关掉，落锁前再确认一次。
if [ "$(cfg_get autostart 1)" != "1" ]; then
  log_to "$BOOTLOG" "autostart 已被关闭，放弃拉起服务"
  exit 0
fi

# 幂等：到达启动步骤时服务可能已被其它路径拉起（热安装 / 手动 a2a start）。
if svc_is_running; then
  log_to "$BOOTLOG" "boot-worker：守护进程已在运行（pid=$(svc_supervisor_pid)），跳过启动"
  # 只报状态，不做任何处置：server 不健康由 supervisor 自己的看护循环恢复。
  svc_http_health 5 || log_to "$BOOTLOG" "boot-worker：健康检查未通过，交给 supervisor 自行恢复"
  exit 0
fi

log_to "$BOOTLOG" "boot-worker：启动守护进程"
svc_start
_bw_rc=$?
exit "$_bw_rc"
