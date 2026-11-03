#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · 安装脚本（customize.sh）
#
# Magisk / KernelSU / APatch 都会设置 MODPATH；update-binary 的兜底路径也会。
# 安装顺序固定为：源文件预检 -> 暂存与自检 -> 配置/工具 -> zoneinfo -> payload。
# payload 是最后一个可能失败的持久数据提交；zoneinfo 已切换而 payload 失败时，
# EXIT 清理会恢复旧 zoneinfo，避免新 payload 与旧时区库（或反向）混用。
# ============================================================================

MODID=agent2api
APP_HOME=/data/adb/agent2api
PAYLOAD="$APP_HOME/payload"
PLIB="$PAYLOAD/lib"
CFGDIR="$APP_HOME/etc"
BINDIR="$APP_HOME/bin"
LOGDIR="$APP_HOME/logs"
DATADIR="$APP_HOME/data"
RUNDIR="$APP_HOME/run"
TMPD="$APP_HOME/tmp"
HOMEDIR="$APP_HOME/home"
BACKUPDIR="$APP_HOME/backup"
DLDIR="$APP_HOME/download"
A2A_LIVE=/data/a2a
SERVER_BIN="$PAYLOAD/agent2api-server"
LOADER="$PLIB/ld-linux-aarch64.so.1"
SETTINGS="$CFGDIR/settings.conf"
CURL="$BINDIR/curl"
CACERT="$BINDIR/cacert.pem"

if [ -z "${MODPATH:-}" ]; then
  MODPATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
fi

command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$1"; }
command -v abort >/dev/null 2>&1 || abort() { echo "! $1"; exit 1; }
command -v set_perm_recursive >/dev/null 2>&1 || set_perm_recursive() {
  chown -R "$2:$3" "$1" 2>/dev/null || return 1
  chmod_tree "$1" "$4" "$5"
}

ui_print " "
ui_print "=================================="
ui_print " Agent2API 服务端 · Android 模块"
ui_print "=================================="

[ -n "${ARCH:-}" ] || ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$ARCH" in
  arm64*|aarch64*) : ;;
  *) abort "只支持 arm64（当前 $ARCH）。模块内置的是 aarch64 的 glibc 运行时。" ;;
esac
ui_print "- 架构检查通过：$ARCH"

_ENV="未知"
if [ "${KSU:-}" = "true" ] || [ -d /data/adb/ksu ]; then
  _ENV="KernelSU ${KSU_VER:-}"
elif [ -d /data/adb/apatch ] || [ -d /data/adb/apd ]; then
  _ENV="APatch"
elif [ -d /data/adb/magisk ]; then
  _ENV="Magisk ${MAGISK_VER:-}"
fi
ui_print "- 运行环境：$_ENV"
ui_print "- 安装路径：$APP_HOME（数据保留，模块升级不动它）"

# ---------------------------------------------------------------------------
# 1) 任何持久写入之前，先检查所有安装源。zoneinfo 的元数据和关键时区都是
#    必需输入；curl/CA/公共库也不再因文件缺失而静默跳过一个坏安装。
# ---------------------------------------------------------------------------
for _required in \
  libexec/common.sh libexec/payload.sh libexec/dns.sh libexec/a2a \
  settings.conf.example tools/curl tools/cacert.pem \
  zoneinfo/VERSION zoneinfo/UTC zoneinfo/Etc/UTC \
  zoneinfo/Asia/Shanghai zoneinfo/tzdata.zi
do
  [ -s "$MODPATH/$_required" ] || abort "模块包不完整：缺少或空文件 $_required"
done

SEED="$MODPATH/seed"
HAVE_SEED=0
[ -d "$SEED" ] && HAVE_SEED=1
if [ "$HAVE_SEED" = "1" ]; then
  for _required in VERSION agent2api-server lib/ld-linux-aarch64.so.1 \
                   lib/libc.so.6 ui/index.html
  do
    [ -s "$SEED/$_required" ] || abort "模块包不完整：缺少或空文件 seed/$_required"
  done
else
  # 精简包只能用于已有完整安装，不能在首次安装时伪造成功。
  [ -s "$SERVER_BIN" ] && [ -s "$LOADER" ] && [ -s "$PAYLOAD/ui/index.html" ] \
    || abort "模块包不完整：缺少 seed/ 目录，系统里也没有可用的载荷"
fi

# ---------------------------------------------------------------------------
# 2) 只创建运行目录，不预建空 payload；首次安装由载荷事务自行创建它。
# ---------------------------------------------------------------------------
ui_print "- 准备运行目录"
for d in "$APP_HOME" "$BINDIR" "$CFGDIR" "$DATADIR" \
         "$LOGDIR" "$RUNDIR" "$TMPD" "$HOMEDIR" "$BACKUPDIR" "$DLDIR" \
         "$A2A_LIVE"; do
  mkdir -p "$d" 2>/dev/null || abort "无法创建 $d"
done
chmod 700 "$CFGDIR" "$DATADIR" 2>/dev/null || abort "无法设置配置/数据目录权限"
chmod 755 "$APP_HOME" "$BINDIR" "$LOGDIR" "$RUNDIR" \
          "$TMPD" "$HOMEDIR" "$BACKUPDIR" "$DLDIR" "$A2A_LIVE" 2>/dev/null \
  || abort "无法设置运行目录权限"
# 残留载荷清理推迟到取得 update.lock.d 之后（见下方）：提前删会把并发事务刚建好的
# payload.new.<pid> 当成垃圾清掉，对方事务就会半途而废。

. "$MODPATH/libexec/common.sh" || abort "无法加载 libexec/common.sh"
. "$MODPATH/libexec/payload.sh" || abort "无法加载 libexec/payload.sh"

# 沿用公共安装/更新锁；整个脚本只有这一处加锁。
update_lock_acquire "$RUNDIR/update.lock.d" || abort "另一个安装/更新事务正在运行，请稍后重试"
# 拿到锁之后再清残留：此时不可能有别人在写 payload.new.*。
rm -rf "$APP_HOME"/payload.new.* "$APP_HOME"/payload.broken.* 2>/dev/null
_INSTALL_TRANSACTION="$APP_HOME/.install.$$"
_ZONE_OLD="$APP_HOME/zoneinfo.old.$$"
_ZONE_COMMITTED=0
_ZONE_OLD_PRESENT=0
_INSTALL_SUCCESS=0
install_cleanup() {
  # 只要旧时区库已经被移开，就必须还原——不管新库有没有"提交"过。
  # 旧实现只在 _ZONE_COMMITTED=1 时还原，于是"移开旧库、新库还没 rename
  # 进来"这个窗口里被中断，两处都不存在，zoneinfo 直接丢失。
  if [ "$_INSTALL_SUCCESS" != "1" ] && [ "$_ZONE_OLD_PRESENT" = "1" ] && [ -d "$_ZONE_OLD" ]; then
    if [ "$_ZONE_COMMITTED" = "1" ] && [ -e "$APP_HOME/zoneinfo" ]; then
      rm -rf "$APP_HOME/zoneinfo" 2>/dev/null
    fi
    if [ ! -e "$APP_HOME/zoneinfo" ]; then
      mv -f "$_ZONE_OLD" "$APP_HOME/zoneinfo" 2>/dev/null
    fi
  fi
  rm -rf "$_INSTALL_TRANSACTION" 2>/dev/null
  update_lock_release "$RUNDIR/update.lock.d"
}
trap 'install_cleanup' EXIT
trap 'exit 1' HUP INT TERM

# ---------------------------------------------------------------------------
# 3) 在独立事务目录暂存全部新文件。权限和 loader 自检均针对暂存副本，
#    因而失败时现有 payload、zoneinfo、curl 和配置尚未被替换。
# ---------------------------------------------------------------------------
rm -rf "$_INSTALL_TRANSACTION" "$_ZONE_OLD" 2>/dev/null
mkdir -p "$_INSTALL_TRANSACTION/payload" "$_INSTALL_TRANSACTION/zoneinfo" \
         "$_INSTALL_TRANSACTION/tools" 2>/dev/null || abort "无法创建安装暂存目录"
_PAYLOAD_STAGE="$_INSTALL_TRANSACTION/payload"
_ZONE_STAGE="$_INSTALL_TRANSACTION/zoneinfo"
_TOOLS_STAGE="$_INSTALL_TRANSACTION/tools"
_SETTINGS_STAGE="$_INSTALL_TRANSACTION/settings.conf"

cp -R "$MODPATH/zoneinfo"/. "$_ZONE_STAGE"/ 2>/dev/null || abort "时区数据库暂存失败"
chmod_tree "$_ZONE_STAGE" 755 644 || abort "时区数据库权限设置失败"
for _required in VERSION UTC Etc/UTC Asia/Shanghai tzdata.zi; do
  [ -s "$_ZONE_STAGE/$_required" ] || abort "时区数据库暂存后缺少 $_required"
done

cp -f "$MODPATH/tools/curl" "$_TOOLS_STAGE/curl" 2>/dev/null || abort "静态 curl 暂存失败"
chmod 755 "$_TOOLS_STAGE/curl" 2>/dev/null || abort "静态 curl 权限设置失败"
cp -f "$MODPATH/tools/cacert.pem" "$_TOOLS_STAGE/cacert.pem" 2>/dev/null || abort "CA 证书暂存失败"
chmod 644 "$_TOOLS_STAGE/cacert.pem" 2>/dev/null || abort "CA 证书权限设置失败"
{
  printf '#!/system/bin/sh\n'
  printf 'exec sh /data/adb/modules/%s/libexec/a2a "$@"\n' "$MODID"
} >"$_TOOLS_STAGE/a2a" 2>/dev/null || abort "a2a 命令暂存失败"
chmod 755 "$_TOOLS_STAGE/a2a" 2>/dev/null || abort "a2a 命令权限设置失败"
if [ ! -f "$SETTINGS" ]; then
  cp -f "$MODPATH/settings.conf.example" "$_SETTINGS_STAGE" 2>/dev/null || abort "默认配置暂存失败"
  chmod 600 "$_SETTINGS_STAGE" 2>/dev/null || abort "默认配置权限设置失败"
fi

install_payload_perms() {
  chmod_tree "$1" 755 644 || return 1
  chmod 755 "$1/agent2api-server" "$1/lib" "$1/lib/ld-linux-aarch64.so.1" 2>/dev/null || return 1
  for _f in "$1/lib/"*.so*; do
    [ -e "$_f" ] || continue
    chmod 755 "$_f" 2>/dev/null || return 1
  done
  return 0
}

if [ "$HAVE_SEED" = "1" ]; then
  ui_print "- 暂存并校验载荷（约 26MB，稍等）"
  _err=$(payload_validate "$SEED" 2>&1) || abort "种子载荷校验失败：$_err"
  cp -R "$SEED"/. "$_PAYLOAD_STAGE"/ 2>/dev/null || abort "载荷暂存失败（可能空间不足）"
  _err=$(payload_validate "$_PAYLOAD_STAGE" 2>&1) || abort "暂存载荷校验失败：$_err"
  _CHECK_PAYLOAD="$_PAYLOAD_STAGE"
else
  payload_validate "$PAYLOAD" >/dev/null 2>&1 || abort "现有载荷不完整，且安装包没有 seed/"
  ui_print "- 包里没有 seed/，保留系统里已装的载荷：$(payload_version)"
  _CHECK_PAYLOAD="$PAYLOAD"
fi
# payload_fix_perms 保持公共库语义；这里的额外显式检查覆盖其历史兼容忽略项。
payload_fix_perms "$_CHECK_PAYLOAD" || abort "载荷权限设置失败"
install_payload_perms "$_CHECK_PAYLOAD" || abort "载荷权限设置失败"

# 模块脚本权限同样 fail-closed；不能把 chmod/chown 失败当成提示继续。
set_perm_recursive "$MODPATH" 0 0 0755 0644 || abort "模块目录权限设置失败"
for f in customize.sh post-fs-data.sh service.sh uninstall.sh action.sh boot-completed.sh hotinstall.sh; do
  if [ -f "$MODPATH/$f" ]; then
    chmod 755 "$MODPATH/$f" 2>/dev/null || abort "模块脚本权限设置失败：$f"
  fi
done
chmod 755 "$MODPATH/libexec" "$MODPATH/libexec/"* 2>/dev/null || abort "libexec 权限设置失败"

ui_print "- 自检：动态链接器"
_CHECK_LOADER="$_CHECK_PAYLOAD/lib/ld-linux-aarch64.so.1"
[ -x "$_CHECK_LOADER" ] || abort "动态链接器没有执行权限"
if _ld_output=$("$_CHECK_LOADER" --version 2>&1); then
  _LDV=$(printf '%s\n' "$_ld_output" | head -n 1)
  [ -n "$_LDV" ] || abort "动态链接器自检没有返回版本信息"
  ui_print "  $_LDV"
else
  abort "动态链接器无法执行，安装已终止"
fi
ui_print "- 自检：服务端架构"
_SA=$(elf_arch "$_CHECK_PAYLOAD/agent2api-server" 2>/dev/null)
[ "$_SA" = "aarch64" ] || abort "服务端架构异常：$_SA"
ui_print "  aarch64 OK"

_patch_bad=""
for _f in "$_CHECK_PAYLOAD/lib/libc.so.6" "$_TOOLS_STAGE/curl"; do
  if ! grep -q '/data/a2a/resolv' "$_f" 2>/dev/null; then
    _patch_bad="$_patch_bad $(basename "$_f")"
  fi
done
[ -z "$_patch_bad" ] || abort "这些文件没有做路径重定向：$_patch_bad"
ui_print "  二进制路径重定向 OK（glibc/curl 都指向 $A2A_LIVE）"

. "$MODPATH/libexec/dns.sh" || abort "无法加载 libexec/dns.sh"
dns_bootstrap || ui_print "  ! DNS/NSS 写入有失败项，开机后会自动重试，可用 a2a doctor 检查"
ui_print "- DNS/NSS 运行时目标：$A2A_LIVE"

# ---------------------------------------------------------------------------
# 4) 持久提交。所有可预检工作已经完成；先提交小型辅助文件，再切 zoneinfo，
#    最后调用公共载荷事务。payload 失败由 install_cleanup 回滚 zoneinfo。
# ---------------------------------------------------------------------------
if [ -f "$SETTINGS" ]; then
  ui_print "- 保留已有配置 $SETTINGS"
else
  mv -f "$_SETTINGS_STAGE" "$SETTINGS" 2>/dev/null || abort "无法提交默认配置"
  ui_print "- 默认配置已生成"
fi
mv -f "$_TOOLS_STAGE/curl" "$CURL" 2>/dev/null || abort "静态 curl 提交失败"
mv -f "$_TOOLS_STAGE/cacert.pem" "$CACERT" 2>/dev/null || abort "CA 证书提交失败"
mv -f "$_TOOLS_STAGE/a2a" "$BINDIR/a2a" 2>/dev/null || abort "a2a 命令提交失败"
ui_print "- 静态 curl 与 CA 证书已就绪"

if [ -e "$APP_HOME/zoneinfo" ]; then
  mv -f "$APP_HOME/zoneinfo" "$_ZONE_OLD" 2>/dev/null || abort "无法暂存旧时区数据库"
  _ZONE_OLD_PRESENT=1
fi
if ! mv -f "$_ZONE_STAGE" "$APP_HOME/zoneinfo" 2>/dev/null; then
  if [ "$_ZONE_OLD_PRESENT" = "1" ]; then
    mv -f "$_ZONE_OLD" "$APP_HOME/zoneinfo" 2>/dev/null
  fi
  abort "时区数据库切换失败"
fi
_ZONE_COMMITTED=1
ui_print "- IANA 时区规则已暂存切换（含夏令时）"

if [ "$HAVE_SEED" = "1" ]; then
  # 直接在安装脚本进程执行，不能放进命令替换子 shell：
  # 子 shell 会丢 UPDATE_LOCK_TOKEN，EXIT 清理就无法按 owner 安全释放锁。
  _PI_LOG="$_INSTALL_TRANSACTION/payload-install.log"
  if payload_install_from "$_PAYLOAD_STAGE" 0 >"$_PI_LOG" 2>&1; then
    while IFS= read -r _l; do [ -n "$_l" ] && ui_print "  $_l"; done <"$_PI_LOG"
    ui_print "  载荷版本：$(payload_version)"
  else
    while IFS= read -r _l; do [ -n "$_l" ] && ui_print "  ! $_l"; done <"$_PI_LOG"
    abort "载荷安装失败：见上一行的具体原因（若提示空间不足，请清理 /data）"
  fi
fi
# 报成功之前把已经落盘的东西刷到闪存：安装器退出后管理器可能立刻杀掉进程，
# 不 sync 的话极少数机器上会出现"装完重启，载荷又变回旧的"。
sync 2>/dev/null
_INSTALL_SUCCESS=1
rm -rf "$_ZONE_OLD" 2>/dev/null
live_link_refresh || ui_print "  ! 动态链接器软链刷新失败，开机后会自动重试"
if lib_snapshot_save; then
  ui_print "  运行时快照已保存（自愈用）"
else
  ui_print "  ! 运行时快照保存失败（不影响使用，只是丢掉自愈能力）"
fi

# 只有全部持久提交成功后才清理模块包内大件。
[ -d "$SEED" ] && rm -rf "$SEED" 2>/dev/null
[ -d "$MODPATH/tools" ] && rm -rf "$MODPATH/tools" 2>/dev/null
[ -d "$MODPATH/zoneinfo" ] && rm -rf "$MODPATH/zoneinfo" 2>/dev/null

{
  printf '[%s] 安装完成\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  printf '  环境      : %s\n' "$_ENV"
  printf '  ARCH/ABI  : %s / %s\n' "${ARCH:-?}" "$(getprop ro.product.cpu.abi 2>/dev/null)"
  printf '  SDK       : %s\n' "$(getprop ro.build.version.sdk 2>/dev/null)"
  printf '  载荷版本  : %s\n' "$(payload_version 2>/dev/null)"
  printf '  链接器    : %s\n' "$_LDV"
  printf '  模块路径  : %s\n' "$MODPATH"
} >>"$INSTLOG" 2>/dev/null
rotate_log "$INSTLOG" 256

if [ "${KSU:-}" = "true" ] && [ ! -f "$CFGDIR/no_hot_install" ]; then
  export MODULE_HOT_INSTALL_REQUEST=true
  export MODULE_HOT_RUN_SCRIPT=hotinstall.sh
  ui_print "- 已申请 KernelSU 热安装（装完立即可用，不用重启）"
fi

ui_print " "
ui_print "=================================="
ui_print " 安装完成"
ui_print "=================================="
_INSTALL_PORT=$(port_normalize "$(cfg_get port 3065)") || _INSTALL_PORT=3065
_INSTALL_PANEL=$(panel_port_effective)
ui_print " 面板: http://127.0.0.1:${_INSTALL_PANEL}/m.html"
[ "$_INSTALL_PANEL" != "$_INSTALL_PORT" ] && \
  ui_print " 网关: http://127.0.0.1:${_INSTALL_PORT}/v1 （面板已拆到 $_INSTALL_PANEL）"
ui_print " 手机: 打开浏览器访问上面的地址，或在模块 App 里点【打开】"
ui_print " "
ui_print " 出问题先跑：su -c 'sh /data/adb/agent2api/bin/a2a doctor'"
ui_print " 看日志   ：su -c 'sh /data/adb/agent2api/bin/a2a logs 50'"
ui_print " "
ui_print " 服务会等系统启动完成 + 网络就绪后自动拉起（约 10~60 秒）"
ui_print " 不想自动启动：a2a config autostart 0"
ui_print "=================================="
