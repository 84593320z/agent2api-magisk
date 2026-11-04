#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · boot-start.sh（开机入口 → 投递 boot-worker）
#
# 由 service.sh 以独立进程方式启动（setsid + 后台）。历史上这个脚本自己
# 承担“等 boot_completed → boot_delay → 等网络 → DNS 三件套 → svc_start”
# 的完整流程；但 KernelSU / APatch 还有第二个入口 boot-completed.sh，旧
# 实现在那边直接做 DNS 初始化并 svc_start，绕过了这里的等待策略，两个
# 入口还可能并行准备 DNS、并行拉起服务。
#
# 现在完整流程统一收进 libexec/boot-worker.sh（独占锁保证全机同一时刻
# 只跑一份），本脚本退化为纯投递：把 worker 丢到后台就立刻返回。仍然
# 保持独立脚本文件、不并回 service.sh 的 `( ... ) &`，原因见 service.sh
# 头部 —— 加锁发生在 worker 里，同样要求它是独立进程（$$ 是自己的 PID）。
# ============================================================================

_self="${0:-}"
case "$_self" in
  */*) MODDIR="${_self%/*}" ;;
  *)   MODDIR="." ;;
esac
# R19：本脚本住在 <模块根>/libexec/ 下，取目录只得到 libexec，模块根是它的
# 上一层。旧实现少了这一层，只“恰好”靠 /data/adb/modules/agent2api 兜底才对；
# 模块目录改名、走 modules_update 或多开时会拿错路径。先向上找一级，再退标准路径。
if [ ! -f "$MODDIR/module.prop" ]; then
  _bs_parent="${MODDIR%/*}"
  if [ -n "$_bs_parent" ] && [ "$_bs_parent" != "$MODDIR" ]; then
    MODDIR="$_bs_parent"
  fi
fi
[ -f "$MODDIR/module.prop" ] || MODDIR="/data/adb/modules/agent2api"

[ -f "$MODDIR/libexec/common.sh" ] || exit 0
. "$MODDIR/libexec/common.sh"

[ -f "$MODDIR/libexec/boot-worker.sh" ] || {
  log_to "$LOGDIR/boot.log" "boot-start.sh：缺少 libexec/boot-worker.sh，无法拉起"
  exit 0
}

log_to "$LOGDIR/boot.log" "boot-start.sh：投递开机流程到 boot-worker（from=service.sh）"

# 独立进程：自己的 PID、自己的会话，父进程退出也不受影响。
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/libexec/boot-worker.sh" service.sh >>"$LOGDIR/boot.log" 2>&1 </dev/null &
else
  sh "$MODDIR/libexec/boot-worker.sh" service.sh >>"$LOGDIR/boot.log" 2>&1 </dev/null &
fi

exit 0
