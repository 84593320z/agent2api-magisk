#!/system/bin/sh
# Agent2API 上游载荷升级：校验下载、事务替换、失败恢复。上层自更新始终禁用。

REPO_SLUG=$(cfg_get update_repo "aimod-cc/Agent2API")
ASSET_NAME=$(cfg_get update_asset "agent2api-server-linux-arm64.tar.gz")
case "$REPO_SLUG" in */*) ;; *) REPO_SLUG="aimod-cc/Agent2API" ;; esac
case "$ASSET_NAME" in *.tar.gz) ;; *) ASSET_NAME="agent2api-server-linux-arm64.tar.gz" ;; esac
UPD_LOCK="$RUNDIR/update.lock.d"
UPD_ACTIVE="$RUNDIR/update.active"
UPD_ABORT=0
UPD_TMP=""
UPD_WAS_RUNNING=0
UPD_INSTALLED=0
UPD_ACTIVATE_BEFORE=""
UPD_ACTIVATE_AFTER=""
UPD_ACTIVE_WRITTEN=0
UPD_LOCK_HELD=0
# 问题 1/2 的完成阶段状态：是否已停服、是否已启动过新版、是否做过数据快照
UPD_SERVICE_STOPPED=0
UPD_SERVICE_STARTED=0
UPD_DATA_SNAP=0

mirror_url() {
  _mu_cfg=$(cfg_get github_mirror)
  case "$_mu_cfg" in
    ghfast) printf 'https://ghfast.top/%s' "$1" ;;
    gh-proxy) printf 'https://mirror.ghproxy.com/%s' "$1" ;;
    ghproxy) printf 'https://ghproxy.net/%s' "$1" ;;
    gh-proxy-com) printf 'https://gh-proxy.com/%s' "$1" ;;
    https://*)
      # 自定义加速前缀：<前缀><原始 URL>。旧实现取的是从未传入的 $2，
      # 结果自定义镜像被静默忽略，流量仍然直连 github。
      _mu_base="${_mu_cfg%/}"
      printf '%s/%s' "$_mu_base" "$1"
      ;;
    *) printf '%s' "$1" ;;
  esac
}

upd_curl() {
  _ca=""; [ -s "$CACERT" ] && _ca="--cacert $CACERT"
  _ua='agent2api-magisk/1.1'
  # 三级降级：自带 curl → 系统 curl → wget（仅配置 update_pin 时允许，见下）。
  # wb2api v1.4.4 的 updater.sh 就是这么排的（bin/curl → curl → bin/wget → wget → busybox wget）：
  # 模块里的静态 curl 万一被杀毒/清理工具删掉或架构不对，"在线升级"不该整条死掉。
  # 只有"跑不起来"（126/127）才降级，网络错误必须原样上报，不能被降级掩盖成成功。
  if [ -x "$CURL" ]; then
    "$CURL" -sS --proto '=https' --tlsv1.2 --user-agent "$_ua" \
      --connect-timeout 15 --speed-time 45 --speed-limit 1024 $_ca "$@" && return 0
    _uc=$?
    [ "$_uc" = "126" ] || [ "$_uc" = "127" ] || return "$_uc"
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -sS --proto '=https' --tlsv1.2 --user-agent "$_ua" \
      --connect-timeout 15 --speed-time 45 --speed-limit 1024 "$@" && return 0
    _uc=$?
    [ "$_uc" = "126" ] || [ "$_uc" = "127" ] || return "$_uc"
  fi
  # wget 回退（问题 14）：busybox/toybox 的 wget 既不校验证书也不强制 TLS
  # 版本，curl 的传输层约束（--proto '=https' --tlsv1.2）在这里全部丢失。
  # 只有配置了 update_pin（固定 digest，完整性由 pin 保证、不依赖传输层）
  # 时才允许走 wget；否则直接报错说明原因，绝不静默降级。
  if [ -z "$(cfg_get update_pin "")" ]; then
    printf '没有可用的 curl，且未配置 update_pin：wget 回退无法保证传输安全，拒绝下载\n' >&2
    return 1
  fi
  # 最后一位只认"-o 文件"这一种用法（本模块所有调用点都是这样）
  _wo=""; _wu=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o) _wo="${2:-}"; shift 2 ;;
      --max-time|--connect-timeout|--user-agent|-U|--speed-time|--speed-limit) shift 2 ;;
      -*) shift ;;
      *) _wu="$1"; shift ;;
    esac
  done
  [ -n "$_wu" ] || return 1
  # 优先 toybox wget、其次 busybox（问题 14）。-T 超时必加；-t 1 仅在该实现
  # 支持时加：本机 busybox/toybox 的 wget 都是单次尝试且无 -t 选项，GNU wget
  # 默认重试 20 次才需要显式限制成 1 次。
  for _wg in toybox /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox /data/adb/apd/bin/busybox; do
    command -v "$_wg" >/dev/null 2>&1 || [ -x "$_wg" ] || continue
    _wg_t=""
    case $("$_wg" wget --help 2>&1) in *"-t"*) _wg_t="-t 1" ;; esac
    if [ -n "$_wo" ]; then
      "$_wg" wget -q -T 60 $_wg_t -O "$_wo" "$_wu" && return 0
    else
      "$_wg" wget -q -T 60 $_wg_t -O - "$_wu" && return 0
    fi
  done
  return 1
}

upd_latest_tag() {
  case "${1:-beta}" in
    beta) _api='releases?per_page=100' ;;
    stable) _api='releases/latest' ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  _json="$TMPD/releases.json"
  _api_url="https://api.github.com/repos/$REPO_SLUG/$_api"
  # 直连优先。国内直连 api.github.com 基本必失败，于是"不挂 VPN 就无法在线升级"。
  # 失败且配了加速镜像时，再用镜像拉一次"版本号列表"（只读元数据，风险最小）；
  # 包体与 sha256 仍然必须走官方，这里不放松任何校验。
  if ! upd_curl --max-time 45 -fL "$_api_url" -o "$_json" 2>/dev/null; then
    if [ "$(cfg_get update_mirror_api 1)" = "1" ] \
       && [ -n "$(cfg_get github_mirror)" ]; then
      _api_mirror=$(mirror_url "$_api_url")
      log_to "$LOGDIR/update.log" "release 直连失败，改走镜像：$_api_mirror"
      upd_curl --max-time 45 -fL "$_api_mirror" -o "$_json" 2>/dev/null || {
        log_to "$LOGDIR/update.log" "release 查询失败（镜像也失败）：$_api"
        return 1
      }
    else
      log_to "$LOGDIR/update.log" "release 查询失败：$_api"
      return 1
    fi
  fi
  if [ "${1:-beta}" = "beta" ]; then
    # GitHub 列表按发布时间，不是版本号。只接受规范 vX.Y.Z[-beta.N]，显式取最大值。
    awk -F'"' '
      # awk 的函数语法，不是 Shell function/bashism。
      function better(a, b,    ca, cb, pa, pb, aa, bb, i, an, bn, xa, xb) {
        # 先去掉 v 前缀：aa[1] 若是 "v3"，aa[1]+0 恒为 0，
        # 主版本号比较等于失效，v4 会被 v3 压住。
        sub(/^v/,"",a); sub(/^v/,"",b)
        # 必须先用 "-" 把主版本和预发布段拆开再按 "." 切：
        # 直接 split(a,aa,".") 时 "3.3.0-beta.10" 会切成
        # 3 / 3 / 0-beta / 10 —— 预发布号落到第四段，前三段里只剩
        # "0-beta"，于是 beta.10 和 beta.6 被当成同一个版本。
        if(index(a,"-")>0){ca=substr(a,1,index(a,"-")-1);pa=substr(a,index(a,"-")+1)}
        else{ca=a;pa=""}
        if(index(b,"-")>0){cb=substr(b,1,index(b,"-")-1);pb=substr(b,index(b,"-")+1)}
        else{cb=b;pb=""}
        split(ca,aa,"."); split(cb,bb,".")
        for(i=1;i<=3;i++){an=aa[i]+0;bn=bb[i]+0;if(an!=bn)return an>bn}
        # 正式版 > 预发布版
        if(pa==""&&pb!="")return 1
        if(pa!=""&&pb=="")return 0
        if(pa==pb)return 0
        split(pa,xa,"."); split(pb,xb,".")
        if(xa[1]!=xb[1])return xa[1]>xb[1]
        # beta.10 > beta.6：按数字比，不能按字符串比
        for(i=2;i<=4;i++){an=xa[i]+0;bn=xb[i]+0;if(an!=bn)return an>bn}
        return 0
      }
      /"tag_name"[[:space:]]*:/ {
        for(i=1;i<=NF;i++)if($i=="tag_name"){
          t=$(i+2)
          if(t ~ /^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z]+(\.[0-9]+)*)?$/ && (best==""||better(t,best)))best=t
        }
      }
      END {if(best!="")print best;else exit 1}
    ' "$_json"
  else
    awk -F'"' '/"tag_name"[[:space:]]*:/ {
      for (i = 1; i <= NF; i++) if ($i == "tag_name") { print $(i + 2); exit }
    }' "$_json"
  fi
}

upd_valid_tag() {
  case "$1" in
    v[0-9A-Za-z][0-9A-Za-z._-]*) case "$1" in *..*|*/*|*\\*) return 1 ;; *) return 0 ;; esac ;;
  esac
  return 1
}

upd_asset_url() {
  upd_valid_tag "$1" || return 1
  case "${2:-}" in ""|.sha256) ;;
    *) return 1 ;;
  esac
  printf 'https://github.com/%s/releases/download/%s/%s%s' \
    "$REPO_SLUG" "$1" "$ASSET_NAME" "${2:-}"
}

upd_download() { # $1=url $2=dest —— 先直连，失败再走镜像
  if upd_curl -fL --max-time 900 --retry 2 --retry-delay 3 --retry-all-errors "$1" -o "$2" 2>/dev/null; then
    printf '  直连下载完成\n'
    return 0
  fi
  _m=$(mirror_url "$1")
  if [ -n "$_m" ] && [ "$_m" != "$1" ]; then
    printf '  直连不可用，改用镜像重试…\n'
    upd_curl -fL --max-time 900 --retry 3 --retry-delay 5 --retry-all-errors "$_m" -o "$2"
    return $?
  fi
  return 1
}

upd_verify_sha256() {
  _expect=$(awk 'NR == 1 {print tolower($1)}' "$1" 2>/dev/null)
  case "$_expect" in *[!0-9a-f]*|'')
    printf '  上游 sha256 文件格式无效\n' >&2; return 1 ;;
  esac
  if [ "${#_expect}" -ne 64 ]; then
    printf '  上游 sha256 长度无效：%s\n' "${#_expect}" >&2; return 1
  fi
  _got=$(sha256_of "$2")
  if [ -z "$_got" ]; then
    printf '  本机没有可用的 SHA-256 工具，拒绝跳过完整性校验\n' >&2
    return 1
  fi
  if [ "$_expect" = "$(printf '%s' "$_got" | tr 'A-F' 'a-f')" ]; then
    printf '  SHA-256 校验通过\n'
    return 0
  fi
  printf '  SHA-256 不匹配：期望 %s，实际 %s\n' "$_expect" "$_got" >&2
  return 1
}

# 先看 tar 清单再解包：禁止绝对路径、..、任何软/硬链接。
upd_tar_safe() {
  tar -tf "$1" 2>/dev/null >"$TMPD/tar.list" || return 1
  awk 'BEGIN { ok = 0 }
    /^\// || /^\.\// || /(^|\/)\.\.($|\/)/ { exit 1 }
    /(^|\/)agent2api-server$/ { ok = 1 }
    END { if (!ok) exit 1 }' "$TMPD/tar.list" || return 1
  tar -tvf "$1" 2>/dev/null | awk 'substr($0,1,1) == "l" || / -> | link to / { bad=1 } END {exit bad?1:0}' || return 1
}

upd_cleanup() {
  trap - TERM INT HUP
  [ -n "$UPD_TMP" ] && rm -rf "$UPD_TMP" 2>/dev/null
  UPD_TMP=""
}

# 先撤信号 trap，再释放事务资源；清理由唯一出口完成，不重复回滚或删新锁。
upd_transaction_finish() { # $1=返回码
  _utf_rc=${1:-0}
  trap - TERM INT HUP
  upd_cleanup
  rm -f "$UPD_ACTIVE" 2>/dev/null
  UPD_ACTIVE_WRITTEN=0
  if [ "$UPD_LOCK_HELD" = "1" ]; then
    update_lock_release "$UPD_LOCK"
    UPD_LOCK_HELD=0
  fi
  return "$_utf_rc"
}

upd_payload_before_move() {
  UPD_ACTIVATE_BEFORE=$1
  UPD_ACTIVATE_AFTER=$2
}
upd_payload_after_move() {
  UPD_INSTALLED=1
  UPD_ACTIVATE_BEFORE=$1
  UPD_ACTIVATE_AFTER=$2
}
upd_payload_commit() {
  # R01：这里只承认「新载荷已就位」，绝不提前清事务身份。
  # UPD_ACTIVATE_BEFORE 指向被移开的旧载荷目录，是健康检查失败或收到信号时
  # 唯一能恢复现场的证据。旧实现在健康检查之前就把它清空，于是
  #   1) 健康失败后 upd_on_signal / 回滚拿不到旧载荷，只能退回 backup/prev；
  #   2) 开机时也没法判断这笔事务还欠一个提交点。
  UPD_INSTALLED=1
}
upd_payload_committed() {
  # 真正的提交点：新载荷已通过健康检查，旧载荷已删除或已确认留待重试。
  UPD_ACTIVATE_BEFORE=""
  UPD_ACTIVATE_AFTER=""
  UPD_COMMITTED=1
}

upd_stop_service() { # 问题 2：停服并核实退出，必须发生在切换 payload 之前
  if [ "$UPD_WAS_RUNNING" = "1" ]; then
    # svc_stop 按 pidfile+cmdline 身份核验：TERM（supervisor 25s / server 10s）
    # 不退再 KILL，仍存活即报失败；这里再兜一层 supervisor 复核。
    svc_stop || { printf '服务停止失败（旧进程仍在），中止更新\n' >&2; return 1; }
    if svc_is_running; then
      printf '服务停止后 supervisor 仍存活，中止更新\n' >&2
      return 1
    fi
  fi
  # 服务端死了，它拉起的插件进程会成为孤儿继续写数据目录。数据快照（问题 1）
  # 要求完全静默：无论更新前是否在运行，快照前都必须清掉残留并核实。
  svc_kill_stray
  _uss_left=$(svc_stray_pids 2>/dev/null)
  if [ -n "$_uss_left" ]; then
    printf '仍有模块相关进程未退出（%s），中止更新\n' "$_uss_left" >&2
    return 1
  fi
  UPD_SERVICE_STOPPED=1
  return 0
}

upd_finish_service() { # 按更新前状态恢复运行；返回健康结果
  # 问题 2：停服已提前到 upd_stop_service（切换之前）。这里只负责
  # 「更新前在运行 -> 现在也必须在运行且健康」；更新前就是停止的直接返回 0
  # （「已安装未验证」是独立状态，见主流程的 pending-verify 分支）。
  if [ "$UPD_WAS_RUNNING" != "1" ]; then
    return 0
  fi
  # 置位在 svc_start 之前：启动期间被信号打断时，数据回滚判定要用它
  UPD_SERVICE_STARTED=1
  svc_start || return 1
  svc_wait_health 45
  return $?
}

upd_restore_service() { # 信号/失败后的服务恢复：在跑就重启到恢复后的载荷，没跑就按原状态启动
  if svc_is_running || [ -n "$(svc_server_pid 2>/dev/null)" ]; then
    svc_restart || return 1
    svc_wait_health 45
    return $?
  fi
  upd_finish_service
}

upd_recover_activation() {
  _ura_before=$UPD_ACTIVATE_BEFORE
  _ura_after=$UPD_ACTIVATE_AFTER
  trap - TERM INT HUP
  log_to "$LOGDIR/update.log" "更新在载荷切换窗口中断，恢复现场"
  case "$_ura_before" in
    "$APP_HOME"/payload.new.old.*|"$APP_HOME"/payload.rollback.old.*)
      [ -d "$_ura_before" ] || {
        log_to "$LOGDIR/update.log" "事务旧载荷已不存在，改用完整备份恢复"
        payload_rollback || return 1
        return 0
      }
      # 新载荷可能完整、嵌套、或根本未落地。必须显式移走，禁止目录嵌套 mv。
      if [ -e "$PAYLOAD" ]; then
        _ura_bad="$APP_HOME/payload.interrupted.$$"
        rm -rf "$_ura_bad" 2>/dev/null
        if ! mv "$PAYLOAD" "$_ura_bad" 2>/dev/null; then
          log_to "$LOGDIR/update.log" "无法移开中断载荷，保留旧版在 $_ura_before"
          return 1
        fi
      fi
      if [ ! -e "$PAYLOAD" ]; then
        mv "$_ura_before" "$PAYLOAD" 2>/dev/null || {
          log_to "$LOGDIR/update.log" "恢复旧载荷失败，旧版仍在 $_ura_before"
          return 1
        }
      fi
      ;;
    *) payload_recover_interrupted || return 1 ;;
  esac
  payload_validate "$PAYLOAD" >/dev/null 2>&1 || {
    log_to "$LOGDIR/update.log" "恢复后的载荷不完整"
    return 1
  }
  live_link_refresh
}

upd_on_signal() {
  trap - TERM INT HUP
  UPD_ABORT=1
  log_to "$LOGDIR/update.log" "更新被信号中断，尝试恢复旧载荷"
  if [ -n "$UPD_ACTIVATE_BEFORE" ]; then
    upd_recover_activation
    # 新版可能已经跑起来写过数据（信号落在健康等待窗口）：恢复载荷后把
    # 数据快照也放回去；新版从未启动过时这是一次内容不变的复制，安全。
    if [ "$UPD_SERVICE_STARTED" = "1" ] && [ "$UPD_DATA_SNAP" = "1" ]; then
      payload_data_rollback || log_to "$LOGDIR/update.log" "数据快照恢复失败，快照保留在 data-prev"
    fi
    upd_restore_service
  elif [ "$UPD_INSTALLED" = "1" ]; then
    # 当前安装器只保留一份完整 prev 备份；已完成的切换也统一走同一代次恢复。
    payload_rollback
    if [ "$UPD_SERVICE_STARTED" = "1" ] && [ "$UPD_DATA_SNAP" = "1" ]; then
      payload_data_rollback || log_to "$LOGDIR/update.log" "数据快照恢复失败，快照保留在 data-prev"
    fi
    upd_restore_service
  elif [ "$UPD_WAS_RUNNING" = "1" ]; then
    # 停服后、切换前被中断（或停服/快照失败中止）：载荷与数据都没动过，
    # 只需按原状态把服务拉回来；服务本来就没停时 svc_start 会发现已在运行。
    upd_finish_service
  fi
  upd_transaction_finish 1
  # 信号/失败收尾必须终止顶层事务。旧实现只 return，回到 upd_do_update
  # 后脚本继续往下跑（还会继续安装、还可能以 0 退出），等于"报中断但没停"。
  exit 1
}

upd_fail() {
  printf '%s\n' "$*" >&2
  upd_on_signal
  return 1
}

upd_do_update() {
  _chan="${1:-beta}"; _force="${2:-0}"
  case "$_chan" in beta|stable) ;; *) upd_valid_tag "$_chan" || { printf '更新通道/tag 无效：%s\n' "$_chan" >&2; return 1; } ;; esac
  mkdir -p "$LOGDIR" "$TMPD" 2>/dev/null
  update_lock_acquire "$UPD_LOCK" 900 || {
    printf '另一个更新/安装任务正在执行\n'; return 1
  }
  UPD_LOCK_HELD=1
  trap 'upd_on_signal' TERM INT HUP
  printf '%s\n' "$$" >"$UPD_ACTIVE" || {
    printf '无法写入更新状态\n'; upd_transaction_finish 1; return 1;
  }
  UPD_ACTIVE_WRITTEN=1
  log_to "$LOGDIR/update.log" "开始更新 chan=$_chan force=$_force"
  # 问题 3：本笔事务的代次 ID。载荷切换（payload_activate_staged）会把它
  # 原子写进代次文件与 pending，健康提交用它把「健康证据」绑定到具体
  # 一次切换，防止删错别的代次的旧载荷。
  PAYLOAD_TXID=$(payload_txid_new)

  if [ -n "${3:-}" ]; then
    _tag="${LOCAL_TAG:-$(payload_version)}"
    case "$_tag" in v*) ;; *) _tag="v$_tag" ;; esac
    printf '本地包更新：%s（版本标签 %s）\n' "$3" "$_tag"
  else
    printf '正在查询上游版本（%s）…\n' "$_chan"
    _tag=$(upd_latest_tag "$_chan")
    if [ -z "$_tag" ]; then
      printf '版本查询失败，请检查网络\n'; upd_transaction_finish 1; return 1
    fi
  fi
  upd_valid_tag "$_tag" || { printf '上游 tag 无效：%s\n' "$_tag"; upd_transaction_finish 1; return 1; }
  printf '上游版本：%s\n当前版本：%s\n' "$_tag" "$(payload_version)"
  _ver="${_tag#v}"
  if [ -z "${3:-}" ] && [ "$_ver" = "$(payload_version)" ] && [ "$_force" != "1" ]; then
    printf '已经是最新版本\n'; upd_transaction_finish 0; return 0
  fi
  _tar="$TMPD/agent2api.tar.gz"; _sha="$TMPD/agent2api.sha256"
  if [ -n "${3:-}" ]; then
    cp -f "$3" "$_tar" || { upd_fail '复制本地包失败'; return 1; }
    if [ -n "${4:-}" ]; then
      printf '%s  %s\n' "$4" "$ASSET_NAME" >"$_sha" || { upd_fail '无法写入校验值'; return 1; }
    elif [ -f "$3.sha256" ]; then
      cp -f "$3.sha256" "$_sha"
    else
      upd_fail '本地包缺少校验值：用 --sha <64位hex> 指定，或把同名 .sha256 放在旁边'; return 1
    fi
  else
    _url=$(upd_asset_url "$_tag") || { upd_transaction_finish 1; return 1; }
    _sha_url=$(upd_asset_url "$_tag" .sha256) || { upd_transaction_finish 1; return 1; }
  fi
  UPD_TMP="$TMPD/upd.$$"
  rm -rf "$UPD_TMP"; mkdir -p "$UPD_TMP" || { upd_transaction_finish 1; return 1; }
  if [ -z "${3:-}" ]; then
    printf '下载载荷…\n'
    upd_download "$_url" "$_tar" || { upd_fail '下载失败'; return 1; }
  fi
  _size=$(wc -c <"$_tar" 2>/dev/null | tr -d ' ')
  case "$_size" in ''|*[!0-9]*) _size=0 ;; esac
  if [ "$_size" -lt 1000000 ] || [ "$_size" -gt 104857600 ]; then
    upd_fail "包体大小异常：$_size 字节"; return 1
  fi
  printf '下载校验文件…\n'
  # 默认哈希必须直连官方 GitHub；加速镜像只承载 tar，不能同时决定哈希与包。
  # 可选 update_pin 是受信 digest：优先级最高，设置后以 pin 为准、不再访问任何
  # 远程 .sha256（包括镜像），适合发布渠道独立校验（问题 12：pin 优先于镜像 SHA）。
  _pin=$(cfg_get update_pin "")
  if [ -n "${3:-}" ]; then
    : # 本地包：校验文件已在上面就位
  elif [ -n "$_pin" ]; then
    printf '%s  %s\n' "$_pin" "$ASSET_NAME" >"$_sha" || { upd_fail '无法写入固定哈希'; return 1; }
  elif ! upd_curl -fL --max-time 90 --retry 2 --retry-all-errors "$_sha_url" -o "$_sha"; then
    # github.com 与 api.github.com 是两个独立域名：很多网络里 API 通、下载域名不通。
    # 官方 sha256 不可达时允许用**同一个镜像**再取一次 —— 注意这确实是信任
    # 降级（镜像可同时伪造包与校验值，见下），不是等价回退；要严格就保持
    # 默认 0，或配置 update_pin 固定 digest。
    if [ "$(cfg_get update_sha_via_mirror 0)" = "1" ]; then
      # 问题 12：开启镜像 sha256 = 真正的信任降级。镜像可以同时伪造包体和
      # 校验值，构造一对自洽的 (tar, sha)，模块无法察觉。明确告警，绝不
      # 让用户误以为这是等价选项。
      log_to "$LOGDIR/update.log" "WARNING: update_sha_via_mirror=1，sha256 改从镜像获取：镜像可同时伪造包与校验值，信任边界已从 GitHub 降级到镜像；建议配置 update_pin 或保持默认 0"
      printf '  WARNING: 镜像 sha256 回退已开启：镜像可同时伪造包与校验值，信任边界已降级\n'
      _mir=$(mirror_url "$_sha_url")
      if [ "$_mir" = "$_sha_url" ]; then
        upd_fail '官方 sha256 下载失败（未配置 github_mirror，无法走镜像）'; return 1
      fi
      printf '  官方 sha256 不可达，改用镜像重试…
'
      upd_curl -fL --max-time 90 --retry 2 --retry-all-errors "$_mir" -o "$_sha" || {
        upd_fail '镜像 sha256 下载也失败，拒绝跳过完整性校验'; return 1;
      }
    else
      upd_fail '官方 sha256 下载失败，拒绝用镜像自证完整性（可设 update_sha_via_mirror=1 或 update_pin）'; return 1
    fi
  fi
  upd_verify_sha256 "$_sha" "$_tar" || { upd_fail 'SHA-256 校验失败'; return 1; }
  upd_tar_safe "$_tar" || { upd_fail 'tar 包含危险路径、链接或缺少服务端'; return 1; }
  tar -xzf "$_tar" -C "$UPD_TMP" || { upd_fail '解包失败'; return 1; }
  _root="$UPD_TMP"
  [ -f "$_root/agent2api-server" ] || _root=$(find "$UPD_TMP" -name agent2api-server -type f 2>/dev/null | head -n 1)
  case "$_root" in */agent2api-server) _root="${_root%/*}" ;; esac
  if [ -z "$_root" ] || [ ! -f "$_root/agent2api-server" ]; then
    upd_fail '压缩包中找不到 agent2api-server'; return 1
  fi
  # 静态载荷不需要 glibc：给它塞 lib 只会让后续 payload_validate 与
  # loader_smoke 的判断自相矛盾（静态包被判成"缺运行时"）。
  if [ ! -d "$_root/lib" ] && ! payload_dir_is_static "$_root"; then
    cp -R "$PAYLOAD/lib" "$_root/lib" && payload_fix_perms "$_root" || { upd_fail '运行时继承失败'; return 1; }
  fi
  {
    printf 'ver=%s\n' "$_ver"
    printf 'built=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
    printf 'source=%s\n' "$REPO_SLUG"
    printf 'arch=arm64\n'
  } >"$_root/VERSION" || { upd_fail '无法写入载荷版本'; return 1; }

  svc_is_running && UPD_WAS_RUNNING=1
  # 问题 2：完成阶段时序重排。旧顺序是「先切载荷 -> upd_finish_service 才停服」，
  # 切换窗口里旧服务端还拿着旧载荷跑，健康证据与磁盘状态脱节；新版迁移过
  # 数据库后回滚更是只剩「旧程序 + 新数据」。新时序：
  #   staging 完成 -> 停服并核实退出 -> 数据快照（问题 1）-> 原子切换 payload ->
  #   （更新前在运行）启动 + svc_wait_health 45 -> 成功才提交；
  #   任一步失败 -> 回滚载荷与数据 -> 按原状态重启旧版 -> 报错退出。
  printf '停止服务并核实退出…\n'
  upd_stop_service || { upd_fail '服务无法停止，更新中止（载荷与数据均未改动）'; return 1; }
  printf '制作数据快照…\n'
  payload_data_snapshot "$PAYLOAD_TXID" || { upd_fail '数据快照失败，中止更新（载荷未动，按原状态恢复服务）'; return 1; }
  [ "$PAYLOAD_DATA_SNAPSHOT_TAKEN" = "1" ] && UPD_DATA_SNAP=1
  printf '安装新载荷并校验…\n'
  payload_install_from "$_root" 1 || { upd_fail '新载荷安装失败，已恢复旧版'; return 1; }
  if [ "$UPD_INSTALLED" != "1" ]; then
    upd_fail '载荷提交状态缺失，恢复旧版'; return 1
  fi
  if [ "$UPD_WAS_RUNNING" = "1" ]; then
    _upd_verify_ok=0
    if upd_finish_service; then
      # 健康证据绑定（问题 3 的 updater 侧）：确认正在服务的进程确实是从新
      # 载荷路径 exec 出来的。切换用的是 rename：旧进程的 /proc/<pid>/exe
      # 会跟着 rename 指到被移走的目录，借此分辨「健康的是不是新版本」，
      # 防止更新窗口里被手工拉起的旧实例顶替健康证据。静态载荷 exe=服务端，
      # 动态载荷 exe=自带 loader，两者都在 $PAYLOAD 下，rename 后即失配。
      _upd_srv=$(svc_server_pid 2>/dev/null)
      _upd_exe=""
      [ -n "$_upd_srv" ] && _upd_exe=$(readlink "/proc/$_upd_srv/exe" 2>/dev/null)
      if [ -z "$_upd_srv" ] \
         || { [ "$_upd_exe" != "$SERVER_BIN" ] && [ "$_upd_exe" != "$LOADER" ]; }; then
        printf '健康检查命中的不是新载荷进程（exe=%s），按失败处理\n' "${_upd_exe:-未知}"
      else
        _upd_verify_ok=1
      fi
    fi
    if [ "$_upd_verify_ok" != "1" ]; then
      printf '新版健康检查失败，正在回滚载荷与数据…\n'
      payload_rollback || printf '载荷回滚失败，请执行 a2a doctor\n'
      if [ "$UPD_DATA_SNAP" = "1" ]; then
        payload_data_rollback || printf '数据快照恢复失败，快照保留在 %s，请执行 a2a doctor\n' "$BACKUPDIR/data-prev"
      fi
      svc_restart
      _upd_rb_ok=1
      if svc_wait_health 45; then
        printf '旧版已恢复并通过健康检查\n'
      else
        printf '旧版未通过健康检查，请执行 a2a doctor 和 a2a logs\n'
        _upd_rb_ok=0
      fi
      # R04：回滚成功后 pending 仍指着刚才失败的那一版。旧版已恢复可用，
      # 这笔事务的「旧载荷」（即失败的 v2）就该提交掉；否则 pending 永远
      # 悬空，下一次开机由守护拿着旧标记去提交，删的是别的代次的目录。
      if [ "$_upd_rb_ok" = "1" ] && payload_validate "$PAYLOAD" >/dev/null 2>&1; then
        if payload_commit_old "rollback $$" "$PAYLOAD_TXID"; then
          upd_payload_committed
          rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
        else
          printf '失败版本暂未删除（见 a2a logs），下次启动健康后自动重试\n'
        fi
      else
        printf '旧版尚未确认健康，保留事务现场：%s\n' \
          "$(awk '{print $3}' "$RUNDIR/update.pending" 2>/dev/null | head -n 1)"
      fi
      upd_transaction_finish 1
      return 1
    fi
    # 新版已经通过健康检查，事务旧载荷这时才允许删除（F-002 两阶段提交）。
    # R03：带上本笔事务的标记与 txid（activate_staged 用 "new $$" 登记），
    # 并发事务后写进来的 pending 不会被误当成自己的。删除动作统一走
    # payload_commit_old（内部持锁 + 代次校验），supervise 侧只是同一条
    # 提交路径的「下轮重试」，不构成第二条删除路径。
    if payload_commit_old "new $$" "$PAYLOAD_TXID"; then
      upd_payload_committed
      # 更新前遗留的「未验证安装」标记随本次已验证提交一并失效（问题 8）
      rm -f "$RUNDIR/update.pending-verify" 2>/dev/null
    else
      printf '事务旧载荷暂未删除（见 a2a logs），下次启动健康后自动重试\n'
    fi
  else
    # 问题 8：更新前服务本就是停止的 —— 「已安装、未启动、未验证」是独立
    # 状态：载荷已切换但手里没有任何健康证据，绝不是"成功"，也绝不能在这
    # 里提交旧载荷。写 pending-verify 标记（含 txid），等下次健康启动由
    # supervise 按代次匹配提交；期间又发生新更新（txid 不匹配）则留给新
    # 事务处理。真正的提交仍走 pending + 代次，标记只是状态记账。
    if printf '%s %s %s %s\n' "$PAYLOAD_TXID" "$(now_epoch)" new "$$" \
       >"$RUNDIR/update.pending-verify.tmp.$$" 2>/dev/null \
       && mv -f "$RUNDIR/update.pending-verify.tmp.$$" "$RUNDIR/update.pending-verify" 2>/dev/null; then
      log_to "$LOGDIR/update.log" "更新已安装未验证（txid=$PAYLOAD_TXID，服务更新前处于停止状态）"
    else
      rm -f "$RUNDIR/update.pending-verify.tmp.$$" 2>/dev/null
      printf '警告：无法写入 pending-verify 标记（提交仍按 pending+代次进行）\n'
    fi
    printf '更新已安装但未验证（服务更新前处于停止状态）：版本 %s\n' "$(payload_version)"
    printf '下次服务健康启动后自动提交旧载荷\n'
  fi
  printf '更新完成：%s\n' "$(payload_version)"
  [ "$UPD_WAS_RUNNING" = "1" ] && printf '服务健康检查通过\n' || printf '保留了更新前的停止状态（已安装未验证）\n'
  log_to "$LOGDIR/update.log" "更新成功 $_tag（txid=$PAYLOAD_TXID verified=$UPD_WAS_RUNNING）"
  upd_transaction_finish 0
  return 0
}