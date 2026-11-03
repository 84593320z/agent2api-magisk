#!/system/bin/sh
# 把 Android persist.sys.timezone 的 IANA 名称交给自带 glibc。
# zoneinfo 随模块携带；TZDIR 不使用 /system、/usr/share 或模块挂载目录。

TZROOT="$APP_HOME/zoneinfo"

zone_name_valid() {
  # IANA 也包含 CET/EET/WET/EST5EDT 这类单段名称。只接受相对、无穿越的
  # 安全路径；是否存在、是否为真正的 TZif 由 zone_file_valid 继续把关。
  case "$1" in
    ''|/*|*/|*//*|*..*|*/./*|./*|*/.|*[!A-Za-z0-9_+/-]*) return 1 ;;
    *) return 0 ;;
  esac
}

zone_file_valid() { # $1=IANA 名称；拒绝软链和伪造/空文件
  zone_name_valid "$1" || return 1
  _zf="$TZROOT/$1"
  [ -f "$_zf" ] && [ ! -L "$_zf" ] && [ -s "$_zf" ] || return 1
  _magic=$(od -An -tc -N4 "$_zf" 2>/dev/null | tr -d ' \t\r\n')
  [ "$_magic" = "TZif" ]
}

zone_candidates() { # 只接受系统当前时区；不把整机属性列表混作候选
  zone_file_valid "${1:-}" && printf '%s\n' "$1"
  case "${1:-}" in
    Asia/Chongqing|Asia/Harbin|Asia/Urumqi) zone_file_valid Asia/Shanghai && printf '%s\n' Asia/Shanghai ;;
    US/Eastern) zone_file_valid America/New_York && printf '%s\n' America/New_York ;;
    US/Central) zone_file_valid America/Chicago && printf '%s\n' America/Chicago ;;
    US/Mountain) zone_file_valid America/Denver && printf '%s\n' America/Denver ;;
    US/Pacific) zone_file_valid America/Los_Angeles && printf '%s\n' America/Los_Angeles ;;
  esac
}

# 输出一行可导入环境：成功=带 DST 的 zoneinfo；明确无 zoneinfo=固定偏移。
# 识别到 Android 时区但文件损坏时返回失败，禁止悄悄退回固定偏移。
zone_export() { # $1=Android persist.sys.timezone
  _candidate=$(zone_candidates "$1" 2>/dev/null | head -n 1)
  if [ -n "$_candidate" ]; then
    printf 'TZDIR=%s\nTZ=%s\nTZ_MODE=zoneinfo\n' "$TZROOT" "$_candidate"
    return 0
  fi
  # 非空但非法/不存在的名称都是配置错误，不能伪装成“系统未提供时区”。
  [ -n "${1:-}" ] && return 1
  # 无 persist.sys.timezone / 显式 UTC 才允许使用固定偏移。
  if [ "$1" = "UTC" ] || [ "$1" = "Etc/UTC" ]; then
    printf 'TZ=UTC0\nTZ_MODE=fixed\n'
    return 0
  fi
  _z=$(date +%z 2>/dev/null)
  case "$_z" in
    [+-][0-9][0-9][0-9][0-9])
      _h=${_z#?}; _sign=${_z%???}; _hh=${_h%??}; _mm=${_h#??}
      case "$_hh" in 0*) _hh=${_hh#0} ;; esac
      case "$_hh" in '') _hh=0 ;; esac
      [ "$_mm" = "00" ] && _tzval="$_hh" || _tzval="$_hh:$_mm"
      [ "$_sign" = "+" ] && _sign='-' || _sign='+'
      printf 'TZ=A2A%s%s\nTZ_MODE=fixed\n' "$_sign" "$_tzval"
      return 0 ;;
  esac
  return 1
}

timezone_apply() {
  _android_tz=$(getprop persist.sys.timezone 2>/dev/null)
  _line=$(zone_export "$_android_tz") || {
    log_to "$SUPLOG" "时区 ${_android_tz:-unknown} 的 zoneinfo 缺失/损坏；保留现有 TZ，不伪装成完整时区"
    return 1
  }
  _old_ifs=$IFS; IFS='
'
  for _kv in $_line; do
    case "$_kv" in TZDIR=*|TZ=*) export "$_kv" ;; esac
  done
  IFS=$_old_ifs
  return 0
}
