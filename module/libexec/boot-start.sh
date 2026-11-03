#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · boot-start.sh（开机后台拉起，独立进程）
#
# 由 service.sh 以独立进程方式启动（setsid + 后台），因此这里的 $$ 就是
# 本进程自己的 PID：加锁时 proc_start_ticks $$ 能正常读到 /proc/$$/stat，
# 事务身份成立。若把这段逻辑写在 service.sh 的 `( ... ) &` 里，$$ 会继承
# 已经退出的父进程 PID，加锁必然失败（见 service.sh 头部说明）。
#
# 流程：等 boot_completed → boot_delay → 等网络 → DNS 三件套 → 插件解释器
#       → svc_start。全程失败都只记日志，不阻塞开机。
# ============================================================================

_self="${0:-}"
case "$_self" in
  */*) MODDIR="${_self%/*}" ;;
  *)   MODDIR="." ;;
esac
[ -f "$MODDIR/module.prop" ] || MODDIR="/data/adb/modules/agent2api"

[ -f "$MODDIR/libexec/common.sh" ] || exit 0
. "$MODDIR/libexec/common.sh"
. "$MODDIR/libexec/control.sh"

log_to "$LOGDIR/boot.log" "boot-start.sh 启动（pid=$$）"

wait_boot_completed 180

_delay=$(cfg_get boot_delay 8)
case "$_delay" in ''|*[!0-9]*) _delay=8 ;; esac
[ "$_delay" -gt 0 ] && sleep "$_delay"

_nw=$(cfg_get net_wait 45)
case "$_nw" in ''|*[!0-9]*) _nw=45 ;; esac
# 等网络超时不是错误（Android 上 net_ready 会因路由表形态误判），但必须留痕迹，
# 否则用户只看到"开机 45 秒后才起来"却查不到原因。
if ! wait_net "$_nw"; then
  log_to "$LOGDIR/boot.log" "等待网络超时（${_nw}s），按无网继续启动；DNS 交给分级兜底"
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
  log_to "$LOGDIR/boot.log" "autostart 已被关闭，放弃拉起服务"
  exit 0
fi

log_to "$LOGDIR/boot.log" "boot-start.sh 启动守护进程"
svc_start
_rc=$?
rotate_log "$LOGDIR/boot.log" 256
exit "$_rc"
