#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · service.sh（late_start service，开机后阶段）
#
# Magisk 会在 late_start 阶段按模块名顺序执行它。KernelSU 同样在开机后执行。
#
# 关键约束：这个脚本必须"立刻返回"。
#   它跑在阻塞路径上，脚本不返回会拖慢开机、也可能被系统判定为"服务卡死"
#   然后连带影响别的模块。所以这里是：检查 → 丢一个后台进程 → exit 0。
#
# 为什么要另起一个脚本文件（而不是 `( ... ) &`）：
#   括号加 & 只是 fork 出一个子 shell，它的 $$ 仍然是本脚本（已经 exit 的
#   那个进程）的 PID。而加锁要靠 $$ 去 /proc/<pid>/stat 读启动代次来证明
#   "这个 PID 还是当初那个进程"，父进程一消失这一步必然失败，svc_start 会
#   被直接拒绝 —— 服务永远起不来。Magisk 没有 boot-completed.sh 兜底，
#   所以这个坑在真机上表现为"装完重启，模块显示已启用但服务不在"。
#   交给独立脚本后，$$ 就是它自己的 PID，身份核对恢复正常。
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

[ "$(cfg_get autostart 1)" = "1" ] || {
  log_to "$LOGDIR/boot.log" "autostart=0，service.sh 不拉起服务"
  exit 0
}

# 已在跑就不重复启动（热安装时旧实例可能还在）
if svc_is_running; then
  log_to "$LOGDIR/boot.log" "service.sh：守护进程已在运行（pid=$(svc_supervisor_pid)），跳过"
  exit 0
fi

[ -f "$MODDIR/libexec/boot-start.sh" ] || {
  log_to "$LOGDIR/boot.log" "service.sh：缺少 libexec/boot-start.sh，无法拉起"
  exit 0
}

# 独立进程：自己的 PID、自己的会话，父进程退出也不受影响。
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/libexec/boot-start.sh" >>"$LOGDIR/boot.log" 2>&1 </dev/null &
else
  sh "$MODDIR/libexec/boot-start.sh" >>"$LOGDIR/boot.log" 2>&1 </dev/null &
fi

exit 0
