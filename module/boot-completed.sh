#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · boot-completed.sh（KernelSU / APatch 专用钩子）
#
# KernelSU 和 APatch 支持 boot-completed.sh，它在 sys.boot_completed=1 之后
# 被调用 —— 比 service.sh 晚，正好是“系统起来了、网络基本就绪”的时刻。
#
# 为什么还要这个：KSU 上 service.sh 也会跑，但如果模块是“热安装”（不重启
# 生效那次）或在某些 ROM 上 service.sh 被跳过，服务就没人拉起。
#
# 旧实现在这里直接做 DNS 初始化并 svc_start：绕过了 boot-start.sh 的
# boot_delay / 网络等待 / autostart 复查，和 service.sh 那一路还可能并行
# 准备 DNS。现在本钩子只做投递：把 libexec/boot-worker.sh 丢到后台，由它
# 拿独占锁串行执行完整开机流程；拿不到锁说明已有一份 worker 在跑
# （worker 自己会记日志并退出 0）。
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

# 已在跑就不重复投递（worker 到达启动步骤时也会再核一次，双保险）。
if svc_is_running; then
  exit 0
fi

[ -f "$MODDIR/libexec/boot-worker.sh" ] || {
  log_to "$LOGDIR/boot.log" "boot-completed.sh：缺少 libexec/boot-worker.sh，无法兜底拉起"
  exit 0
}

log_to "$LOGDIR/boot.log" "boot-completed.sh：守护进程不在，投递到 boot-worker 兜底"

# 独立进程：自己的 PID、自己的会话，父进程退出也不受影响。
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/libexec/boot-worker.sh" boot-completed.sh >>"$LOGDIR/boot.log" 2>&1 </dev/null &
else
  sh "$MODDIR/libexec/boot-worker.sh" boot-completed.sh >>"$LOGDIR/boot.log" 2>&1 </dev/null &
fi

exit 0
