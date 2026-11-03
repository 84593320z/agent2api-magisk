#!/system/bin/sh
# ============================================================================
# Agent2API Magisk 模块 · uninstall.sh
#
# 顺序很重要：先停进程，再考虑要不要删数据。
# 默认不删数据（purge_on_uninstall=0），这样重装模块时账号、签到记录还在。
# ============================================================================

MODDIR="${MODDIR:-/data/adb/modules/agent2api}"

# 卸载以 root 运行。公共库缺失时必须立刻退出，绝不能在空路径变量下继续 rm。
[ -f "$MODDIR/libexec/common.sh" ] || {
  printf '卸载中止：缺少 %s/libexec/common.sh，未执行任何删除\n' "$MODDIR" >&2
  exit 1
}
. "$MODDIR/libexec/common.sh" 2>/dev/null || {
  printf '卸载中止：common.sh 加载失败，未执行任何删除\n' >&2
  exit 1
}
[ -f "$MODDIR/libexec/control.sh" ] || {
  printf '卸载中止：缺少 control.sh，未执行任何删除\n' >&2
  exit 1
}
. "$MODDIR/libexec/control.sh" 2>/dev/null || {
  printf '卸载中止：control.sh 加载失败，未执行任何删除\n' >&2
  exit 1
}
command -v svc_stop >/dev/null 2>&1 && command -v cfg_get >/dev/null 2>&1 || {
  printf '卸载中止：关键函数不完整，未执行任何删除\n' >&2
  exit 1
}

# 删除前一次性核对所有目标。路径必须等于模块自己的固定绝对路径，且不能是软链。
_uninstall_path_ok() {
  [ -n "$1" ] && [ "$1" = "$2" ] && [ ! -L "$1" ]
}
_uninstall_path_ok "$APP_HOME" /data/adb/agent2api &&
_uninstall_path_ok "$RUNDIR" /data/adb/agent2api/run &&
_uninstall_path_ok "$TMPD" /data/adb/agent2api/tmp &&
_uninstall_path_ok "$DLDIR" /data/adb/agent2api/download &&
_uninstall_path_ok "$BACKUPDIR" /data/adb/agent2api/backup &&
_uninstall_path_ok "$A2A_LIVE" /data/a2a || {
  printf '卸载中止：删除路径校验失败，未执行任何删除\n' >&2
  exit 1
}

date '+uninstall %Y-%m-%d %H:%M:%S' >>"$LOGDIR/boot.log" 2>/dev/null

# 1) 正常停止
svc_stop 2>/dev/null

# 2) 兜底：清掉本模块拉起的任何残留进程（不用 pkill -f，避免误杀）
if command -v svc_stray_pids >/dev/null 2>&1; then
  for _p in $(svc_stray_pids 2>/dev/null); do
    kill -TERM "$_p" 2>/dev/null
  done
  sleep 2
  for _p in $(svc_stray_pids 2>/dev/null); do
    kill -KILL "$_p" 2>/dev/null
  done
fi

# 3) 清运行态；不再触碰 /system，也没有任何 bind mount 需要撤。
rm -f "$RUNDIR/stop" "$RUNDIR/server.pid" "$RUNDIR/server.start" "$RUNDIR/supervisor.pid" "$RUNDIR/supervisor.start" "$RUNDIR/hot-restart.state" 2>/dev/null
rm -rf "$RUNDIR/lock" "$RUNDIR/service.lock.d" "$RUNDIR/hot-restart.lock.d" "$RUNDIR/update.lock.d" "$TMPD" 2>/dev/null
rm -rf /data/local/tmp/agent2api_install* 2>/dev/null

# 4) 无论是否保留账号数据，都移除模块私有的 glibc 配置和 ld.so 链接。
rm -rf "$A2A_LIVE" 2>/dev/null

# 5) 是否连数据一起删。只删已核对的目录本身，不使用可能扩成 /* 的变量通配符。
if [ "$(cfg_get purge_on_uninstall 0)" = "1" ]; then
  rm -rf "$APP_HOME" 2>/dev/null
else
  # 留下数据但把大文件清掉（下载缓存、旧备份），省空间。
  rm -rf "$DLDIR" "$BACKUPDIR/prev" "$BACKUPDIR/prev.old" "$BACKUPDIR/prev.new" 2>/dev/null
  rotate_log "$SRVLOG" 512 2>/dev/null
  rotate_log "$APPLOG" 512 2>/dev/null
  rotate_log "$SUPLOG" 512 2>/dev/null
  printf '模块已卸载，数据保留在 %s\n' "$APP_HOME" >"$APP_HOME/UNINSTALLED.txt" 2>/dev/null
fi

exit 0
