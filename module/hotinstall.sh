#!/system/bin/sh
# KernelSU / APatch 热安装钩子。hot-run 有短时限，这里绝不同步停服、启动或等健康。
_self="${0:-}"
case "$_self" in
  */*) MODDIR="${_self%/*}" ;;
  *)   MODDIR="." ;;
esac
[ -f "$MODDIR/module.prop" ] || MODDIR="/data/adb/modules/agent2api"

[ -f "$MODDIR/libexec/common.sh" ] || exit 0
. "$MODDIR/libexec/common.sh" || exit 0
. "$MODDIR/libexec/control.sh" || exit 0

log_to "$LOGDIR/boot.log" "hotinstall.sh 开始（仅登记后台重启）"
_was_running=0
svc_is_running && _was_running=1
_auto=$(cfg_get autostart 1)
case "$_auto" in 0|1) ;; *) _auto=1 ;; esac

ensure_layout

# 热安装可能重置模块权限；只恢复本模块脚本，不遍历大文件。
if [ -d "$MODDIR/libexec" ]; then
  chmod 755 "$MODDIR/libexec" "$MODDIR/libexec"/* 2>/dev/null
fi
for _f in customize.sh post-fs-data.sh service.sh uninstall.sh action.sh boot-completed.sh hotinstall.sh; do
  [ -f "$MODDIR/$_f" ] && chmod 755 "$MODDIR/$_f" 2>/dev/null
done

# customize.sh 已完成载荷校验/原子切换。hook 只保存状态并立即脱钩返回。
printf '%s|%s\n' "$_was_running" "$_auto" >"$RUNDIR/hot-restart.state.new" 2>/dev/null &&
  mv -f "$RUNDIR/hot-restart.state.new" "$RUNDIR/hot-restart.state" 2>/dev/null || {
    log_to "$LOGDIR/boot.log" "热安装：无法写入后台任务状态，保留当前服务，重启后生效"
    exit 0
  }

if command -v setsid >/dev/null 2>&1; then
  setsid sh "$MODDIR/libexec/hot-restart.sh" "$_was_running" "$_auto" >>"$LOGDIR/boot.log" 2>&1 </dev/null &
else
  sh "$MODDIR/libexec/hot-restart.sh" "$_was_running" "$_auto" >>"$LOGDIR/boot.log" 2>&1 </dev/null &
fi
log_to "$LOGDIR/boot.log" "hotinstall.sh 已返回；DNS/插件/重启在后台执行"
exit 0
