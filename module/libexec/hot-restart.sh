#!/system/bin/sh
# hotinstall.sh 的脱钩子工作进程：不受 Root 管理器 hot-run 时限约束。
MODDIR="${MODDIR:-/data/adb/modules/agent2api}"
. "$MODDIR/libexec/common.sh" || exit 1
. "$MODDIR/libexec/control.sh" || exit 1
. "$MODDIR/libexec/dns.sh" || exit 1
. "$MODDIR/libexec/plugin.sh" || exit 1

ensure_layout

# 状态由 hotinstall.sh 通过命令行参数传入（$1=安装前是否在跑 $2=autostart）。
# 以前用 $RUNDIR/hot-restart.state 传递，会被上一个实例的 EXIT trap 或
# post-fs-data.sh 的清理抢先删掉，导致读到空值 → 误判成 autostart=0 →
# 热安装后服务不启动。参数不会丢，文件只作诊断用。
_was_running="${1:-}"
_auto="${2:-}"
case "$_was_running" in 0|1) ;; *) _was_running=0 ;; esac
case "$_auto" in 0|1) ;; *) _auto=1 ;; esac

# 等 Root 管理器先结束 hotinstall hook，避免与目录替换/进程清理竞争。
# 同一时刻只允许一个后台重启；已有任务会读取最新状态，不重复停启。
sleep 2
update_lock_acquire "$RUNDIR/hot-restart.lock.d" 120 || exit 0
HOT_RESTART_ACTIVE=1
hot_restart_cleanup() {
  trap - EXIT HUP INT TERM
  update_lock_release "$RUNDIR/hot-restart.lock.d"
  rm -f "$RUNDIR/hot-restart.state" 2>/dev/null
  HOT_RESTART_ACTIVE=0
}
trap 'trap - HUP INT TERM; hot_restart_cleanup; exit 1' HUP INT TERM
trap 'hot_restart_cleanup' EXIT
log_to "$LOGDIR/boot.log" "后台重启任务启动：was_running=$_was_running autostart=$_auto"
# 热安装属于"启动路径"，和 service.sh 一样走带验活的分级兜底；
# 验活全失败时 dns_ensure 自己会把原配置写回，所以再用 dns_bootstrap 兜一层。
dns_ensure || dns_bootstrap
live_link_refresh
plugin_interp_fix

if [ "$_was_running" = "1" ] || [ "$_auto" = "1" ]; then
  if svc_restart && svc_wait_health 45; then
    log_to "$LOGDIR/boot.log" "热安装后台重启完成，联合健康检查通过"
  else
    log_to "$LOGDIR/boot.log" "热安装后台重启未通过健康检查，详见 supervisor.log/server.log"
    exit 1
  fi
else
  log_to "$LOGDIR/boot.log" "热安装后台任务完成，保留手动停止/autostart=0 状态"
fi
hot_restart_cleanup
exit 0
