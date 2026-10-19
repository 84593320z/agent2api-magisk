#!/system/bin/sh
# Magisk 安装时的定制脚本（由 Magisk 安装器 source 执行，不要加 exit）

ui_print "- Agent2API 网关（arm64 / glibc chroot）"
ui_print "- 程序：rootfs/opt/agent2api/agent2api-server"
ui_print "- 数据：/data/adb/agent2api（升级模块不会丢）"

# 目录与权限
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/rootfs/opt/agent2api/agent2api-server" 0 0 0755
set_perm "$MODPATH/rootfs/lib/ld-linux-aarch64.so.1" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/bin/ctl" 0 0 0755
set_perm "$MODPATH/bin/lib.sh" 0 0 0755
# 只读加固的 bind 占位文件（rootfs 挂成只读后没法现场创建）
set_perm "$MODPATH/rootfs/bin/busybox" 0 0 0644
set_perm "$MODPATH/rootfs/dev/null" 0 0 0644
set_perm "$MODPATH/rootfs/dev/zero" 0 0 0644
set_perm "$MODPATH/rootfs/dev/random" 0 0 0644
set_perm "$MODPATH/rootfs/dev/urandom" 0 0 0644

# /etc/localtime 兜底：TZ 环境变量正常时不看它，但用户把 TZ_NAME 写错
# （Asia/Shanghia 之类）时 chrono/glibc 会退回 /etc/localtime —— 没有这个文件
# 就静默变 UTC，报表时间整体错 8 小时。指向 rootfs 内的 tzdata，符号链接目标
# 在 chroot 里依然有效。
if [ -f "$MODPATH/rootfs/usr/share/zoneinfo/Asia/Shanghai" ]; then
  rm -f "$MODPATH/rootfs/etc/localtime" 2>/dev/null
  ln -s /usr/share/zoneinfo/Asia/Shanghai "$MODPATH/rootfs/etc/localtime" 2>/dev/null
fi

# 首装判定：首装才发默认配置、才解除 disable；
# 升级场景必须尊重用户上一次的停用意图（v3.1.0 的 rm -f disable 会把
# 用户手动 ctl stop 的服务在升级重启后悄悄拉起来，覆盖用户意图）
#
# v3.1.2 修复：FRESH 的语义是「这次是不是全新安装」，不是「数据目录有没有被初始化过」。
# 卸载会故意保留 /data/adb/agent2api（含 .installed 与 disable），于是「卸载→重装」
# 会被误判成升级（FRESH=0），disable 残留 → 守护每次开机第一行就退出，
# 模块显示已安装、status 全是"未运行"，重刷重启都没用，只能手动 ctl start。
# 判据：模块目录还在 = 升级；模块目录没了 = 全新安装。
MARKER=/data/adb/agent2api/.installed
FRESH=1
if [ -f "$MARKER" ] && [ -d /data/adb/modules/agent2api ]; then
  FRESH=0
fi

mkdir -p /data/adb/agent2api/logs /data/adb/agent2api/data 2>/dev/null
if [ "$FRESH" = "1" ] && [ ! -f /data/adb/agent2api/env.sh ]; then
  cp -f "$MODPATH/config/default.env" /data/adb/agent2api/env.sh
  chmod 0600 /data/adb/agent2api/env.sh
fi

# 升级覆盖前先停掉旧进程：老二进制还在跑时替换文件，chmod 会 EBUSY
# 先记录升级前服务是否在跑：安装器自己调 ctl stop 会落下 disable 标记，
# 若升级前正在运行，升级后应恢复自启（否则"运行中升级→重启后服务消失"）
_WAS_RUNNING=0
_SP=$(cat /data/adb/agent2api/supervisor.pid 2>/dev/null)
if [ -n "$_SP" ] && [ -r "/proc/$_SP/cmdline" ]; then
  if tr '\0' ' ' < "/proc/$_SP/cmdline" 2>/dev/null | grep -qF "service.sh --loop"; then
    _WAS_RUNNING=1
  fi
fi
if [ -x "$MODPATH/bin/ctl" ]; then
  sh "$MODPATH/bin/ctl" stop >/dev/null 2>&1
  sleep 1
fi
{ [ "$FRESH" = "1" ] || [ "$_WAS_RUNNING" = "1" ]; } && rm -f /data/adb/agent2api/disable

# 点分数字版本比较（纯 shell，安装器环境没有 awk 也不能依赖）：
# _ver_gt A B → A>B 时返回 0；支持 v 前缀与 -beta 后缀
_ver_gt() {
  _a=${1#v}; _b=${2#v}
  _a=${_a%%-*}; _b=${_b%%-*}
  while :; do
    _x=${_a%%.*}; _y=${_b%%.*}
    [ -n "$_x" ] || _x=0
    [ -n "$_y" ] || _y=0
    _x=$(printf '%s' "$_x" | sed 's/^0*//'); [ -n "$_x" ] || _x=0
    _y=$(printf '%s' "$_y" | sed 's/^0*//'); [ -n "$_y" ] || _y=0
    if [ "$_x" -gt "$_y" ]; then return 0; fi
    if [ "$_x" -lt "$_y" ]; then return 1; fi
    case "$_a" in *.*) _a=${_a#*.} ;; *) _a= ;; esac
    case "$_b" in *.*) _b=${_b#*.} ;; *) _b= ;; esac
    [ -z "$_a" ] && [ -z "$_b" ] && return 1
    [ -z "$_a" ] && _a=0
    [ -z "$_b" ] && _b=0
  done
}

# 在线更新层仲裁：模块包内置的服务端版本更高（说明底座更新带上了新载荷）时，
# 停用旧的在线更新层，避免"新底座 + 旧载荷"的倒挂
if [ -f /data/adb/agent2api/update/version ] && [ -f "$MODPATH/rootfs/opt/agent2api/VERSION" ]; then
  _bundled=$(cat "$MODPATH/rootfs/opt/agent2api/VERSION" 2>/dev/null)
  _ovl=$(cat /data/adb/agent2api/update/version 2>/dev/null)
  if [ -n "$_bundled" ] && _ver_gt "$_bundled" "$_ovl"; then
    mv /data/adb/agent2api/update /data/adb/agent2api/update.superseded 2>/dev/null
    ui_print "- 内置服务端（$_bundled）高于在线更新层（$_ovl），已停用旧更新层"
  fi
fi

# 旧版本目录下遗留的挂载点必须卸掉：Magisk 升级要删除
# /data/adb/modules/agent2api，里面的 proc / bind 挂载会让 rm 报 EBUSY，
# 留下一个"新包已装、旧目录还在"的半更新状态。
# v3.1.1 起 rootfs 自身会挂只读 bind，unmount 列表按路径匹配天然把它盖住
# （sort -r 保证深的挂载点先卸，rootfs 自身的 bind 最后卸）。
OLDROOT=/data/adb/modules/agent2api/rootfs
if [ -d "$OLDROOT" ]; then
  for _mp in $(grep -F " $OLDROOT" /proc/mounts 2>/dev/null | cut -d' ' -f2 | sort -r); do
    umount "$_mp" 2>/dev/null || umount -l "$_mp" 2>/dev/null
  done
fi

touch "$MARKER"

ui_print "- 安装完成，重启后自动启动"
ui_print "- 管理命令：sh /data/adb/modules/agent2api/bin/ctl status|doctor|restart|update check|log"
ui_print "- v3.1.2：日志轮转/只读加固/孤儿进程/守护拉起/内存看门狗/端口冲突诊断 一批修复"
ui_print "- 本包：env.sh 可设 AGENT2API_REPO=owner/name 自定义更新仓库"
ui_print "-       （上游被封/搬家时切换，删除该行即回默认仓库）"
