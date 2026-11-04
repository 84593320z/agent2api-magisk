#!/system/bin/sh
# agent2api 本地修复重打包 · 安装脚本（localfix-20261104）
#
# 设计原则（刻意保持最小，绝不让安装失败）：
#   - 只做三件事：包完整性预检、权限恢复、把包内文件原子复制进现有模块目录；
#     复制全部成功后调用 live 目录的 hotinstall.sh 触发后台热应用（免重启）。
#   - 绝不下载、不停服、不启动、不等健康——这些全部交给 hotinstall.sh 的后台链路。
#   - 任何一步失败只提示、不改退出码（管理器安装流程照常完成，重启后仍可生效）。
#   - 本包不含服务端载荷：全新安装请先用官方完整包。

# ---------- 定位包目录：管理器给 MODPATH；手动执行则用 $0 所在目录 ----------
PKG="${MODPATH:-}"
if [ -z "$PKG" ] || [ ! -f "$PKG/module.prop" ]; then
  case "$0" in
    */*) PKG="${0%/*}" ;;
    *)   PKG="." ;;
  esac
fi
if [ ! -f "$PKG/module.prop" ]; then
  echo "customize: 包内缺少 module.prop（包损坏？），不做任何操作"
  exit 0
fi

# ---------- 输出：管理器提供 ui_print 时用它，否则退化为 echo ----------
command -v ui_print >/dev/null 2>&1 || ui_print() { echo "$*"; }

# live 目录可用环境变量覆盖（仅用于沙箱测试，正常安装无需设置）
LIVE="${A2A_PKG_LIVE_DIR:-/data/adb/modules/agent2api}"

ui_print "**********************************************"
ui_print "  agent2api 本地修复重打包 localfix-20261104"
ui_print "  脚本基线: v3.3.0-beta.7 (magisk.32)"
ui_print "  修复范围: 更新事务/数据回滚/cgroup 逃逸/"
ui_print "  启动钩子统一/卸载安全/DNS 恢复/WebUI 转义等"
ui_print "**********************************************"

# ---------- 完整性预检 ----------
_miss=0
for _f in module.prop service.sh post-fs-data.sh boot-completed.sh \
          hotinstall.sh uninstall.sh action.sh settings.conf.example \
          libexec/common.sh libexec/control.sh libexec/payload.sh \
          libexec/supervise.sh libexec/updater.sh libexec/launch.sh \
          libexec/hot-restart.sh libexec/boot-start.sh libexec/boot-worker.sh \
          libexec/dns.sh libexec/plugin.sh libexec/timezone.sh libexec/a2a \
          webroot/index.html; do
  [ -f "$PKG/$_f" ] || { ui_print "包内缺少: $_f"; _miss=1; }
done
if [ "$_miss" = "1" ]; then
  ui_print "包不完整：跳过就地应用，请重新获取完整的 localfix 包"
  exit 0
fi

# ---------- 权限恢复（管理器解包偶发丢失执行位）----------
chmod 755 "$PKG"/*.sh "$PKG"/libexec/* 2>/dev/null
chmod 644 "$PKG"/module.prop "$PKG"/settings.conf.example "$PKG"/docs/* "$PKG"/webroot/* 2>/dev/null

# ---------- 就地升级分支 ----------
if [ -d "$LIVE" ] && [ -f "$LIVE/module.prop" ] && [ -f "$LIVE/libexec/common.sh" ]; then
  if [ "$PKG" = "$LIVE" ]; then
    ui_print "包目录与模块目录相同（手动原地执行），跳过复制"
    exit 0
  fi
  ui_print "检测到现有安装：原子替换脚本并热应用（免重启）..."
  _tmp_list="$LIVE/.pkglist.$$"
  ( cd "$PKG" && find . -type f ! -name 'customize.sh' | sort ) >"$_tmp_list" 2>/dev/null
  _fail=0
  _n=0
  while IFS= read -r _rel; do
    [ -n "$_rel" ] || continue
    _dst="$LIVE/$_rel"
    case "$_rel" in */*) mkdir -p "${_dst%/*}" 2>/dev/null ;; esac
    if cp -p "$PKG/$_rel" "$LIVE/$_rel.pkgnew.$$" 2>/dev/null \
       && mv -f "$LIVE/$_rel.pkgnew.$$" "$_dst" 2>/dev/null; then
      _n=$((_n + 1))
    else
      ui_print "复制失败: $_rel"
      rm -f "$LIVE/$_rel.pkgnew.$$" 2>/dev/null
      _fail=1
    fi
  done <"$_tmp_list"
  rm -f "$_tmp_list" 2>/dev/null
  chmod 755 "$LIVE"/*.sh "$LIVE"/libexec/* 2>/dev/null

  if [ "$_fail" = "1" ]; then
    ui_print "有文件未就位：跳过热应用，重启手机后生效；建议检查存储后重试"
    exit 0
  fi
  ui_print "已就位 $_n 个文件"
  if [ -f "$LIVE/hotinstall.sh" ]; then
    ui_print "触发热应用（后台重启服务，不阻塞安装）..."
    if sh "$LIVE/hotinstall.sh" >/dev/null 2>&1; then
      ui_print "已登记后台重启：几秒内自动完成，无需重启手机"
    else
      ui_print "热应用登记失败：重启手机后生效"
    fi
  else
    ui_print "live 目录缺少 hotinstall.sh：重启手机后生效"
  fi
else
  ui_print "未检测到现有安装（$LIVE 不存在或不完整）。"
  ui_print "注意：本重打包只含脚本、不含服务端载荷；"
  ui_print "全新安装请先刷官方完整包，再用本包覆盖恢复修复脚本。"
fi
exit 0
