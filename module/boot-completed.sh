#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · boot-completed.sh（KernelSU / APatch 专用钩子）
#
# KernelSU 和 APatch 支持 boot-completed.sh，它在 sys.boot_completed=1 之后
# 被调用 —— 比 service.sh 晚，正好是"系统起来了、网络基本就绪"的时刻。
#
# 为什么还要这个：KSU 上 service.sh 也会跑，但如果模块是"热安装"（不重启
# 生效那次）或在某些 ROM 上 service.sh 被跳过，服务就没人拉起。这里做兜底：
# boot_completed 之后如果发现守护进程没在跑，就拉起来。
#
# Magisk 不认识这个文件，会当成普通文件忽略 —— 零副作用。
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

[ "$(cfg_get autostart 1)" = "1" ] || exit 0

if svc_is_running; then
  exit 0
fi

log_to "$LOGDIR/boot.log" "boot-completed.sh：守护进程不在，兜底拉起"
ensure_layout
. "$MODDIR/libexec/dns.sh"
dns_ensure
nss_apply
gai_apply
live_link_refresh
svc_start
exit 0