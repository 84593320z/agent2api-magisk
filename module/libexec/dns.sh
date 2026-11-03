#!/system/bin/sh
# ============================================================================
# Agent2API 模块 · DNS / NSS / GAI 运行时文件管理
#
# 背景（为什么完全不走 /system/etc）：
#   自带 glibc 只认三个文件：resolv.conf、nsswitch.conf、gai.conf。
#   Android 的 bionic 一条都不读（它走 netd）。所以以前的做法是把这三个文件
#   塞进模块的 system/etc 让 Magisk/KSU 覆盖过去 —— 但这条路在 KernelSU 上
#   直接断了：KSU 只有在装了 metamodule（meta-overlayfs 之类）时才挂载
#   system/ 目录，没装就是"文件存在但没人看"。
#   更糟的是，为了兜底去 mount --bind /system/etc 曾经出过大事故（旧模块把
#   整个目录顶掉，public.libraries.txt 消失，所有 app_process 的 JVM abort）。
#
#   现在的做法：打包时用 patch_elf.py 把二进制里写死的
#     /etc/resolv.conf(16) -> /data/a2a/resolv(16)
#     /etc/gai.conf(13)    -> /data/a2a/gai(13)
#     /etc/nsswitch.conf(18)-> /data/a2a/nsswitch(18)
#   等长原地改写（不新增段、不改偏移、不改文件长度），glibc 读的就是这三个
#   普通文件。于是：零挂载、零命名空间、零 /system 写入，Magisk / KSU /
#   APatch 同一套逻辑，也不可能再出挂载事故。
# ============================================================================

valid_ipv4() {
  case "$1" in
    ''|*[!0-9.]*|.*|*.) return 1 ;;
  esac
  _dots=$(printf '%s' "$1" | tr -dc '.' | wc -c | tr -d ' ')
  [ "$_dots" = "3" ] || return 1
  case "$1" in *..*) return 1 ;; esac
  _oldifs="$IFS"; IFS=.
  set -- $1
  IFS="$_oldifs"
  [ "$#" = "4" ] || return 1
  for _n in "$@"; do
    case "$_n" in ''|*[!0-9]*) return 1 ;; esac
    [ "$_n" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

DNS_ACTIVE_CACHE="$RUNDIR/dns-active"
DNS_VPN_CACHE="$RUNDIR/dns-vpn"

# 出口接口：root 进程实际走哪条路由就是哪条（VPN 下会是 tun0）。
# 只看 ip route 的 default 行在 VPN/策略路由下会误判成 wlan0，所以先问 route get。
dns_default_iface() {
  _di=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [ -n "$_di" ] || _di=$(ip route 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [ -n "$_di" ] || _di=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  [ -n "$_di" ] || _di=$(ip -6 route 2>/dev/null | awk '/^default /{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
  printf '%s' "$_di"
}

dns_vpn_active() {
  case "$(dns_default_iface 2>/dev/null)" in tun*|ppp*|wg*|tap*|utun*) return 0 ;; esac
  # 有 UP 状态的 tun/wg 网卡才算 VPN 在跑（没连的客户端不会建网卡）。
  # 旧实现的裸 grep 'VPN' 会把"装过客户端"也算成 VPN，进而走错分支。
  if command -v ip >/dev/null 2>&1; then
    ip -o link 2>/dev/null \
      | grep -qE ': (tun|ppp|wg|tap|utun|ipsec)[0-9A-Za-z_.-]*: <[^>]*UP' && return 0
    return 1
  fi
  command -v dumpsys >/dev/null 2>&1 || return 1
  dumpsys connectivity 2>/dev/null | grep -Eiq 'TRANSPORT_VPN|type[ =:]+VPN'
}

dns_log_policy() {
  _vpn=0
  dns_vpn_active && _vpn=1
  [ -f "$DNS_VPN_CACHE" ] && _old=$(cat "$DNS_VPN_CACHE" 2>/dev/null) || _old=""
  if [ "$_vpn" != "$_old" ]; then
    if [ "$_vpn" = "1" ]; then
      log_to "$SUPLOG" "检测到 VPN：glibc 无法使用 netd 的 per-netId/Private DNS；仅使用当前出口网络的可见 DNS"
    else
      log_to "$SUPLOG" "当前未检测到 VPN；DNS 使用出口接口/系统可见解析器"
    fi
    printf '%s
' "$_vpn" >"$DNS_VPN_CACHE" 2>/dev/null
  fi
}

dns_active_netid() {
  dumpsys connectivity 2>/dev/null | sed -n 's/^Active default network:[[:space:]]*//p' | head -n 1 | tr -dc '0-9'
}

dns_local_addrs() {
  ip -4 addr 2>/dev/null | awk '/inet /{sub(/\/.*/,"",$2); print $2}'
}

# 候选 IPv4 是否值得写进 resolv.conf：排除本机地址、保留段与组播段。
dns_ip_usable() {
  case "$1" in
    *:*)
      # IPv6 nameserver：glibc 完全支持，旧实现把它整条丢掉，
      # IPv6-only / DNS64 网络下就等于“没有任何 DNS”。
      case "$1" in ::1|::|fe80:*|ff*) return 1 ;; esac
      case "$1" in *[!0-9A-Fa-f:.]*) return 1 ;; esac
      return 0
      ;;
  esac
  valid_ipv4 "$1" || return 1
  case "$1" in
    0.*|127.*|169.254.*|255.255.255.255) return 1 ;;
    224.*|225.*|226.*|227.*|228.*|229.*|230.*|231.*|232.*|233.*|234.*|235.*|236.*|237.*|238.*|239.*) return 1 ;;
  esac
  for _lu in $_DNS_LOCAL; do
    [ "$_lu" = "$1" ] && return 1
  done
  return 0
}

# 首选来源：dumpsys dnsresolver。它按 NetId 分块，块内 "DNS servers:" 是
# 该网络真正在用的解析器，"Interface names:" 标明是哪块网卡。
# 只取"出口接口那一块"；接口对不上时退回活动 netId 那一块。
dns_from_resolver() { # $1=出口接口 $2=活动 netId
  dumpsys dnsresolver 2>/dev/null | awk -v want_if="$1" -v want_net="$2" '
    function flush() {
      if (ips != "") {
        hit = 0
        if (want_if != "" && ifc != "") {
          n = split(ifc, a, ",")
          for (i = 1; i <= n; i++) { gsub(/[ \t]/, "", a[i]); if (a[i] == want_if) hit = 1 }
        }
        if (hit == 0 && want_net != "" && net == want_net) hit = 1
        if (hit == 1) {
          n = split(ips, b, " ")
          for (i = 1; i <= n; i++) if (b[i] != "") print b[i]
        }
      }
      ips = ""; ifc = ""; net = ""; inlist = 0
    }
    /^NetId: / { flush(); net = $2; next }
    /DNS servers:/ { inlist = 1; next }
    inlist == 1 && ($1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ \
                     || $1 ~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]+$/) { ips = ips " " $1; next }
    /Interface names:/ {
      inlist = 0
      s = $0; sub(/.*Interface names:[ \t]*\[/, "", s); sub(/\].*/, "", s); ifc = s
      flush()
      next
    }
    END { flush() }
  '
}

# 次选来源：dumpsys connectivity。一条 NetworkAgentInfo 里 InterfaceName 与
# DnsAddresses 同块。旧实现按整行切词，会把 Routes 里的
# "0.0.0.0/0 -> 192.168.3.1"、"1.0.0.0/8 -> 0.0.0.0" 当成 DNS 写进 resolv.conf。
dns_from_connectivity() { # $1=出口接口
  dumpsys connectivity 2>/dev/null | awk -v want_if="$1" '
    function emit() {
      if (ifc == "" || ips == "") return
      if (want_if != "" && ifc != want_if) return
      n = split(ips, a, /[][,\/ \t]+/)
      for (i = 1; i <= n; i++)
        if (a[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || a[i] ~ /^[0-9A-Fa-f]*:[0-9A-Fa-f:.]+$/) print a[i]
    }
    /NetworkAgentInfo\{/ { ifc = ""; ips = "" }
    ifc == "" && match($0, /InterfaceName:[ \t]*[^ \t,\]]+/) {
      s = substr($0, RSTART, RLENGTH); sub(/InterfaceName:[ \t]*/, "", s); ifc = s
    }
    match($0, /DnsAddresses:[ \t]*\[[^]]*\]/) {
      s = substr($0, RSTART, RLENGTH); sub(/DnsAddresses:[ \t]*\[/, "", s); sub(/\]$/, "", s); ips = s
      emit()
    }
  '
}

# 从系统里把当前 DNS 抓出来（只保留可用的 IPv4，多来源按优先级取第一个非空）
dns_collect_system() {
  _found=""
  _iface=$(dns_default_iface 2>/dev/null)
  _netid=$(dns_active_netid 2>/dev/null)
  _DNS_LOCAL=$(dns_local_addrs 2>/dev/null | tr '
' ' ')
  _vpn=0
  case "$_iface" in tun*|ppp*|wg*) _vpn=1 ;; esac

  # VPN 出口下只认"隧道自己"的解析器：dnsresolver 里接口是 tun*/ppp*/wg* 的块。
  # 绝不能再回退到底层物理网卡（wlan0/rmnet）那一段 —— 那些地址走直连路由，
  # 查询会绕过隧道泄漏到局域网/运营商，等于把 VPN 的 DNS 策略拆了。
  if [ "$_vpn" = "1" ]; then
    _found=$(dns_from_resolver "$_iface" "" 2>/dev/null)
  else
    # 0) 出口网络真正在用的解析器（dnsresolver 分块，接口优先、netId 兜底）
    _found=$(dns_from_resolver "$_iface" "$_netid" 2>/dev/null)

    # 1) 同一 NetworkAgentInfo 的 DnsAddresses
    if [ -z "$_found" ]; then
      _found=$(dns_from_connectivity "$_iface" 2>/dev/null)
    fi

    # 2) 出口接口的 DHCP 属性
    if [ -z "$_found" ] && [ -n "$_iface" ]; then
      for _k in dns1 dns2 dns3 dns4; do
        _v=$(getprop "dhcp.$_iface.$_k" 2>/dev/null)
        [ -n "$_v" ] && _found="$_found $_v"
      done
    fi

    # 3) 老式全局属性
    if [ -z "$_found" ]; then
      for _k in net.dns1 net.dns2 net.dns3 net.dns4; do
        _v=$(getprop "$_k" 2>/dev/null)
        [ -n "$_v" ] && _found="$_found $_v"
      done
    fi
  fi

  # 4) 厂商 DNS 属性（仅非 VPN 且仍为空）
  if [ "$_vpn" = "0" ] && [ -z "$_found" ]; then
    _v=$(getprop 2>/dev/null \
         | sed -n 's/^\[[a-zA-Z0-9._]*[dD][nN][sS][a-zA-Z0-9._]*\]: \[\([0-9A-Fa-f][0-9A-Fa-f:.]*\)\]$/\1/p')
    [ -n "$_v" ] && _found="$_found $(printf '%s' "$_v" | tr '
' ' ')"
  fi

  # 5) ROM 自带 resolv.conf 只作最后兜底
  if [ -z "$_found" ] && [ -r /system/etc/resolv.conf ]; then
    _v=$(sed -n 's/^[[:space:]]*nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' /system/etc/resolv.conf 2>/dev/null)
    [ -n "$_v" ] && _found="$_found $(printf '%s' "$_v" | tr '
' ' ')"
  fi

  if [ -z "$_found" ] && [ "$_vpn" = "1" ]; then
    # 隧道没暴露自己的 DNS（透明代理类 VPN 很常见）。这时写公共解析器，
    # 让查询走默认路由进隧道，由 VPN 自己劫持/转发；仍然不碰底层网卡。
    _found=$(dns_static_list)
    # 只在“当前生效的首选”真的变了才写日志：这函数每 2 分钟跑一次，
    # 无脑 log 会把 supervisor.log 刷满。
    _vp_first=$(printf '%s' "$_found" | awk '{print $1}')
    _vp_cur=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNSFILE" 2>/dev/null | head -n 1)
    [ "$_vp_first" = "$_vp_cur" ] || log_to "$SUPLOG" "VPN 出口未暴露 DNS，改用公共解析器经隧道（不泄漏到底层网络）"
  fi

  for _s in $_found; do
    dns_ip_usable "$_s" || continue
    printf 'nameserver %s
' "$_s"
  done
}

# 生成内容 → 写入 /data/a2a/resolv（glibc 直接读的那个文件）
dns_write() {
  _mode="${1:-$(cfg_get dns_mode auto)}"
  if [ "$_mode" = "off" ]; then
    log_to "$SUPLOG" "dns_mode=off，跳过 resolv.conf 维护"
    return 0
  fi
  case "$_mode" in auto|system|static) ;; *) return 1 ;; esac

  _tmp="$TMPD/resolv.$$"
  _final="$TMPD/resolv.final.$$"
  rm -f "$_tmp" "$_final" 2>/dev/null
  : >"$_tmp" 2>/dev/null || return 1

  case "$_mode" in
    static)
      # 显式 dns_static= 是用户选择禁用静态地址，不是“使用公共 DNS”。
      for _s in $(cfg_get dns_static "223.5.5.5 119.29.29.29"); do
        dns_ip_usable "$_s" || continue
        printf 'nameserver %s
' "$_s" >>"$_tmp" 2>/dev/null || {
          rm -f "$_tmp"; return 1;
        }
      done
      ;;
    system)
      # system 只读 ROM 文件，禁止借用 auto 的采样、缓存或静态地址。
      _DNS_LOCAL=$(dns_local_addrs 2>/dev/null | tr '
' ' ')
      if [ -r /system/etc/resolv.conf ]; then
        for _s in $(sed -n 's/^[[:space:]]*nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' /system/etc/resolv.conf 2>/dev/null); do
          dns_ip_usable "$_s" || continue
          printf 'nameserver %s
' "$_s" >>"$_tmp" 2>/dev/null || {
            rm -f "$_tmp"; return 1;
          }
        done
      fi
      ;;
    auto)
      dns_collect_system >>"$_tmp" 2>/dev/null || { rm -f "$_tmp"; return 1; }
      # 只有 auto 能保留最后可用配置，或使用静态地址作首次启动兜底。
      if ! awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_tmp" 2>/dev/null; then
        if [ -s "$DNS_CACHE" ] && awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$DNS_CACHE" 2>/dev/null; then
          rm -f "$_tmp" 2>/dev/null
          log_to "$SUPLOG" "暂时未取得活动网络 DNS；保留最后可用配置，不跳公共 DNS"
          return 0
        fi
        # 静态兜底也要分家族：IPv6-only / NAT64 网络上 v4 解析器根本到不了。
        _fb=$(cfg_get dns_static "223.5.5.5 119.29.29.29")
        if command -v ip >/dev/null 2>&1 \
           && ! ip -4 addr 2>/dev/null | grep -q 'inet .*scope global'; then
          _fb6=$(cfg_get dns_static_v6 "2400:3200::1 2402:4e00::")
          [ -n "$_fb6" ] && _fb="$_fb6 $_fb"
        fi
        for _s in $_fb; do
          dns_ip_usable "$_s" || continue
          printf 'nameserver %s
' "$_s" >>"$_tmp" 2>/dev/null || {
            rm -f "$_tmp"; return 1;
          }
        done
      fi
      ;;
  esac

  # 先验证再 cp/mv，确保不会把只有 options 的配置当成成功结果。
  if ! awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_tmp" 2>/dev/null; then
    rm -f "$_tmp" "$_final" 2>/dev/null
    log_to "$SUPLOG" "DNS 无有效服务器（mode=$_mode），保留现有配置"
    return 1
  fi

  {
    printf '# generated by agent2api-magisk %s (mode=%s)
' "$(now_human)" "$_mode" || exit 1
    printf '# 这是本模块自带 glibc 的解析器配置，手机本体 bionic 不读它
' || exit 1
    awk '/^nameserver/ { if (seen[$2]++) next } { print }' "$_tmp" 2>/dev/null \
      | head -n 8 || exit 1
    dns_opts_line || exit 1
  } >"$_final" 2>/dev/null || {
    rm -f "$_tmp" "$_final" 2>/dev/null
    log_to "$SUPLOG" "DNS 临时文件写入失败（mode=$_mode）"
    return 1
  }
  rm -f "$_tmp" 2>/dev/null
  if ! awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_final" 2>/dev/null; then
    rm -f "$_final" 2>/dev/null
    return 1
  fi

  # 落盘：先写 tmp 再 mv（原子），避免服务端正好在解析时读到半截文件。
  cp -f "$_final" "$DNSFILE.new" 2>/dev/null || {
    rm -f "$_final" "$DNSFILE.new" 2>/dev/null; log_to "$SUPLOG" "DNS 写入失败（空间/权限）"; return 1;
  }
  chmod 644 "$DNSFILE.new" 2>/dev/null || {
    rm -f "$_final" "$DNSFILE.new" 2>/dev/null; return 1;
  }
  mv -f "$DNSFILE.new" "$DNSFILE" 2>/dev/null || {
    rm -f "$_final" "$DNSFILE.new" 2>/dev/null; return 1;
  }
  cp -f "$_final" "$DNS_CACHE" 2>/dev/null || { rm -f "$_final" 2>/dev/null; return 1; }
  chmod 644 "$DNS_CACHE" 2>/dev/null || { rm -f "$_final" 2>/dev/null; return 1; }

  _want=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$_final" 2>/dev/null | head -n 1)
  _got=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNSFILE" 2>/dev/null | head -n 1)
  rm -f "$_final" 2>/dev/null
  if [ -z "$_got" ] || [ "$_want" != "$_got" ]; then
    log_to "$SUPLOG" "警告：$DNSFILE 写入后内容不符（want=${_want:-none} got=${_got:-none}）"
    return 1
  fi
  _iface=$(dns_default_iface 2>/dev/null)
  printf '%s
' "${_iface:-unknown}" >"$DNS_ACTIVE_CACHE" 2>/dev/null
  dns_log_policy
  log_to "$SUPLOG" "DNS 已更新（mode=$_mode, iface=${_iface:-unknown}, 首选=$_got）"
  return 0
}

# nsswitch：glibc 决定"先查 hosts 还是先问 DNS"的地方。
# 不写这个文件时 glibc 有内建默认，但显式写更可控：先 files（/etc/hosts，
# 这里会读不到 = ENOENT 无害）再 dns。
# 关键点：dns 模块 libnss_dns.so.2 通过 LD_LIBRARY_PATH 从 $PLIB 里 dlopen。
nss_apply() {
  [ -d "$A2A_LIVE" ] || mkdir -p "$A2A_LIVE" 2>/dev/null
  _want='hosts: files dns
networks: files
passwd: files
group: files
shadow: files
services: files
protocols: files
rpc: files
ethers: files
netmasks: files
netgroup: files
publickey: files
automount: files
aliases: files'
  _cur=""
  [ -r "$NSSFILE" ] && _cur=$(cat "$NSSFILE" 2>/dev/null)
  [ "$_cur" = "$_want" ] && return 0
  printf '%s
' "$_want" >"$NSSFILE.new" 2>/dev/null || return 1
  chmod 644 "$NSSFILE.new" 2>/dev/null
  mv -f "$NSSFILE.new" "$NSSFILE" 2>/dev/null || return 1
  [ "$(cat "$NSSFILE" 2>/dev/null)" = "$_want" ] || return 1
  log_to "$SUPLOG" "nsswitch.conf 已写入 $NSSFILE"
  return 0
}

# /data/a2a/resolv 现在能不能用（给 doctor / status 用）
dns_probe() {
  _want=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNS_CACHE" 2>/dev/null | head -n 1)
  _got=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNSFILE" 2>/dev/null | head -n 1)
  printf '%s|%s' "${_want:-none}" "${_got:-none}"
}

# ---------------------------------------------------------------------------
# 分级兜底 + 自愈 —— “不开 VPN 也能用”的核心
#
# 旧实现只有“写”没有“验”：首次采样写进一个不可达的地址后，只要网络不变
# 就永远不会重写，于是只能靠开 VPN 换一条 DNS 才救得回来。
#
# 每一级写完立刻验活（用模块自带 curl，走的就是这份 resolv），命中即停：
#   0) 上次验证通过的列表（自愈记忆，开机后第一次就不走弯路）
#   1) 系统采样（IPv4 + IPv6 一起收）
#   2) 系统采样 + 静态兜底（隧道不暴露 DNS / 运营商劫持 53 时靠它）
#   3) 纯静态兜底（按本机地址家族排序，v6-only 网络把 v6 排前面）
# 四级全失败也不覆盖现有配置，避免把“还能凑合用”的结果写得更糟。
# 全程零 mount、零 iptables、零新进程：只是往 /data/a2a/resolv 写文件。
# ---------------------------------------------------------------------------
dns_liveness_ok() {
  [ "$(cfg_get dns_probe 1)" = "1" ] || return 0
  # 验活必须真的验：没有 curl 就返回失败，不能"假装成功"——
  # 那样会把一个根本不可达的 DNS 记进 dns.lastgood，之后每次都优先用它。
  [ -x "$CURL" ] || { log_to "$SUPLOG" "缺少 $CURL，无法验证 DNS 可用性"; return 1; }
  _dl_url=$(cfg_get dns_probe_url "http://connect.rom.miui.com/generate_204")
  _dl_code=""
  # -f 让 4xx/5xx 直接失败；再显式核对状态码，避免被劫持页/错误页骗过。
  # --noproxy：验活走的是刚写进去的解析链，不能被系统代理截胡。
  _dl_rc=0
  case "$_dl_url" in
    https://*) _dl_code=$("$CURL" -sS -f --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 6 --cacert "$CACERT" "$_dl_url" 2>/dev/null) || _dl_rc=$? ;;
    *)         _dl_code=$("$CURL" -sS -f --noproxy '*' -o /dev/null -w '%{http_code}' --max-time 6 "$_dl_url" 2>/dev/null) || _dl_rc=$? ;;
  esac
  # R13：必须同时满足 curl 退出码 0 与 200/204。只看状态码时，连接被中途截断
  # （curl 18/56，响应头已到）会被判成可用，把一个坏解析链记进 dns.lastgood，
  # 之后每次开机都优先用它，域名解析变慢甚至直接失败。
  if [ "$_dl_rc" -ne 0 ]; then
    log_to "$SUPLOG" "DNS 验活失败（curl rc=$_dl_rc）：$_dl_url"
    return 1
  fi
  case "$_dl_code" in
    200|204) return 0 ;;
  esac
  log_to "$SUPLOG" "DNS 验活失败（HTTP ${_dl_code:-none}）：$_dl_url"
  return 1
}

dns_static_list() { # 静态兜底的合并列表，按本机地址家族排序
  _sl=$(cfg_get dns_static "223.5.5.5 119.29.29.29")
  _sl6=$(cfg_get dns_static_v6 "2400:3200::1 2402:4e00::")
  if command -v ip >/dev/null 2>&1 \
     && ! ip -4 addr 2>/dev/null | grep -q 'inet .*scope global'; then
    printf '%s %s' "$_sl6" "$_sl"
  else
    printf '%s %s' "$_sl" "$_sl6"
  fi
}

dns_ipv6_usable() { # 先看路由表（几十毫秒），真有 v6 默认路由才值得去 curl
  # Android 每个 netId 有独立路由表，只查 main 表在多数机型上恒为空，
  # 结果是永远判定"没有 IPv6"，resolv.conf 里被加上 no-aaaa，
  # 双栈域名于是退化成只有 A 记录。table all 覆盖所有表。
  _v6rt=""
  if command -v ip >/dev/null 2>&1; then
    _v6rt=$(ip -6 route show table all default 2>/dev/null)
    [ -n "$_v6rt" ] || _v6rt=$(ip -6 route show default 2>/dev/null)
  fi
  [ -n "$_v6rt" ] || return 1
  [ -n "${CURL:-}" ] && [ -x "${CURL:-}" ] || return 1
  "$CURL" -6 -sS -m 3 -o /dev/null "http://ipv6.baidu.com/" >/dev/null 2>&1 && return 0
  return 1
}

dns_no_aaaa_state() { # 输出 1=在 resolv.conf 里加 no-aaaa，0=不加
  _nd=$(cfg_get dns_no_aaaa auto)
  case "$_nd" in
    1|yes|on|true)  echo 1; return 0 ;;
    0|no|off|false) echo 0; return 0 ;;
  esac
  _nf="$A2A_LIVE/dns.aaaa"
  _nnow=$(date +%s 2>/dev/null); case "$_nnow" in ''|*[!0-9]*) _nnow=0 ;; esac
  if [ -f "$_nf" ]; then
    _nts=$(sed -n 's/^ts=//p' "$_nf" 2>/dev/null | head -n 1)
    _nv=$(sed -n 's/^no_aaaa=//p' "$_nf" 2>/dev/null | head -n 1)
    case "$_nts" in ''|*[!0-9]*) _nts=0 ;; esac
    if [ -n "$_nv" ] && [ $((_nnow - _nts)) -lt 10800 ]; then echo "$_nv"; return 0; fi
  fi
  if dns_ipv6_usable; then _nv=0; else _nv=1; fi
  printf 'ts=%s\nno_aaaa=%s\n' "$_nnow" "$_nv" >"$_nf" 2>/dev/null
  echo "$_nv"
}

dns_opts_line() { # $1=noprobe 时只读缓存（开机早期用），否则现场探测
  if [ "${1:-}" = "noprobe" ]; then
    _ov=$(sed -n 's/^no_aaaa=//p' "$A2A_LIVE/dns.aaaa" 2>/dev/null | head -n 1)
  else
    _ov=$(dns_no_aaaa_state 2>/dev/null)
  fi
  if [ "$_ov" = "1" ]; then
    printf 'options timeout:2 attempts:2 single-request-reopen no-aaaa\n'
  else
    printf 'options timeout:2 attempts:2 single-request-reopen\n'
  fi
}

dns_apply_list() { # $1=候选（空格分隔）；去重、限 6 条、写入并回填缓存
  _al=""
  for _s in $1; do
    dns_ip_usable "$_s" || continue
    case " $_al " in *" $_s "*) continue ;; esac
    _al="${_al:+$_al }$_s"
  done
  [ -n "$_al" ] || return 1
  _at="$TMPD/resolv.$$.tmp"
  {
    printf '# generated by agent2api-magisk %s (auto/ladder)\n' "$(now_human)"
    printf '# 这是本模块自带 glibc 的解析器配置，手机本体 bionic 不读它\n'
    printf '%s\n' $_al | head -n 6 | sed 's/^/nameserver /'
    dns_opts_line || exit 1
  } >"$_at" 2>/dev/null || { rm -f "$_at"; return 1; }
  chmod 644 "$_at" 2>/dev/null
  # 必须是 rename 级原子替换。cp 直接覆盖会先把目标截断再写，
  # 正在读 resolv.conf 的解析器可能读到半截文件（nameserver 行被切断），
  # 表现就是随机解析失败。
  if ! cp -f "$_at" "$DNSFILE.new.$$" 2>/dev/null; then
    rm -f "$_at" "$DNSFILE.new.$$"; return 1
  fi
  chmod 644 "$DNSFILE.new.$$" 2>/dev/null
  mv -f "$DNSFILE.new.$$" "$DNSFILE" 2>/dev/null || { rm -f "$_at" "$DNSFILE.new.$$"; return 1; }
  cp -f "$_at" "$DNS_CACHE" 2>/dev/null
  rm -f "$_at" 2>/dev/null
  # 变更检测依赖这两个缓存；dns_ensure 走的是本函数，必须在这里同步，
  # 否则 dns_refresh_if_changed 永远认为"网络变了"，每轮都重写一遍。
  _ai=$(dns_default_iface 2>/dev/null)
  printf '%s' "${_ai:-unknown}" >"$DNS_ACTIVE_CACHE" 2>/dev/null
  _av=0
  dns_vpn_active 2>/dev/null && _av=1
  printf '%s' "$_av" >"$DNS_VPN_CACHE" 2>/dev/null
  return 0
}

dns_ensure() { # 分级兜底入口：任何调用点都可以直接用它替代 dns_write
  _emode=$(cfg_get dns_mode auto)
  if [ "$_emode" != "auto" ]; then dns_write "$_emode"; return $?; fi
  [ -d "$TMPD" ] || mkdir -p "$TMPD" 2>/dev/null
  _esys=$(dns_collect_system 2>/dev/null \
          | sed -n 's/^nameserver[[:space:]]*\([^[:space:]]*\).*/\1/p' \
          | awk '{printf "%s ", $1}')
  _esl=$(dns_static_list)
  _elgf="$A2A_LIVE/dns.lastgood"
  _elgl=""
  [ -s "$_elgf" ] && _elgl=$(awk '{printf "%s ", $1}' "$_elgf" 2>/dev/null)
  # 现役配置整文件留一份：四级都失败时原样写回，绝不把“还能凑合”的结果弄更糟。
  # 只记 nameserver 会把 search/options/注释全部丢掉，回滚反而更糟。
  _eback="$TMPD/resolv.orig.$$"
  rm -f "$_eback" 2>/dev/null
  # R14：备份失败就不能开始改。旧实现无视 cp 失败，一旦四级候选全部不可用，
  # 回滚只能走「仅回填 nameserver」的降级路径，search/ndots/注释会被整段丢掉。
  if [ -s "$DNSFILE" ]; then
    if ! cp -f "$DNSFILE" "$_eback" 2>/dev/null || [ ! -s "$_eback" ]; then
      rm -f "$_eback" 2>/dev/null
      log_to "$SUPLOG" "无法备份现有 DNS 配置（$_eback），放弃本次改写"
      return 1
    fi
  fi
  _eorig=""
  [ -s "$DNSFILE" ] && _eorig=$(sed -n 's/^nameserver[[:space:]]*//p' "$DNSFILE" 2>/dev/null | awk '{printf "%s ", $1}')

  # 默认「静态优先」：公网 DNS 只要能用就固定用它，不跟随系统变化，
  # 这样开关 VPN / 切节点时一个字节都不用改（和 wb2api、magpie 的体感一致）。
  # dns_follow_system=1 恢复老行为（跟随系统采样优先）。
  if [ "$(cfg_get dns_follow_system 0)" = "1" ]; then
    _e1="$_elgl"; _e2="$_esys"; _e3="$_esys $_esl"; _e4="$_esl"
  else
    _e1="$_elgl"; _e2="$_esl"; _e3="$_esys"; _e4="$_esys $_esl"
  fi
  for _ecand in "$_e1" "$_e2" "$_e3" "$_e4"; do
    [ -n "$_ecand" ] || continue
    dns_apply_list "$_ecand" || continue
    if dns_liveness_ok; then
      printf '%s\n' $_ecand | head -n 6 >"$_elgf" 2>/dev/null
      chmod 644 "$_elgf" 2>/dev/null
      log_to "$SUPLOG" "DNS 生效并验证通过：$(printf '%s ' $_ecand)"
      # R14：成功也要收拾临时备份，否则每次 DNS 生效都往 tmp 里留一份整文件副本。
      rm -f "$_eback" 2>/dev/null
      return 0
    fi
  done
  if [ -s "$_eback" ]; then
    if cp -f "$_eback" "$DNSFILE.restore.$$" 2>/dev/null \
       && chmod 644 "$DNSFILE.restore.$$" 2>/dev/null \
       && mv -f "$DNSFILE.restore.$$" "$DNSFILE" 2>/dev/null; then
      cp -f "$DNSFILE" "$DNS_CACHE" 2>/dev/null
      log_to "$SUPLOG" "DNS 分级兜底均未通过验活，已整文件还原原配置（$(dns_probe)）"
    else
      rm -f "$DNSFILE.restore.$$" 2>/dev/null
      [ -n "$_eorig" ] && dns_apply_list "$_eorig"
      log_to "$SUPLOG" "DNS 分级兜底均未通过验活，整文件还原失败，仅回填 nameserver（$(dns_probe)）"
    fi
    rm -f "$_eback" 2>/dev/null
    return 1
  fi
  [ -n "$_eorig" ] && dns_apply_list "$_eorig"
  log_to "$SUPLOG" "DNS 分级兜底均未通过验活，保留现有配置（$(dns_probe)）"
  return 1
}

# 每 2 分钟被 supervisor 调一次。变化就重来一遍兜底；没变化时按
# dns_verify_interval（默认 600s）抽检一次，避免每轮都发探测请求。
# 只在系统 DNS 变化时才重写，避免无意义的写盘
dns_refresh_if_changed() {
  [ "$(cfg_get dns_mode auto)" = "auto" ] || return 0
  # 只看「网卡/默认路由/VPN」三项变化（都靠 ip 命令，几十毫秒），
  # 不再每轮跑 dumpsys 采样——那才是以前体感卡顿的来源。
  _old_iface=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null)
  _new_iface=$(dns_default_iface 2>/dev/null)
  [ -f "$DNS_VPN_CACHE" ] && _old_vpn=$(cat "$DNS_VPN_CACHE" 2>/dev/null) || _old_vpn=0
  _new_vpn=0
  dns_vpn_active && _new_vpn=1

  _iv=$(cfg_get dns_verify_interval 600)
  case "$_iv" in ''|*[!0-9]*) _iv=600 ;; esac
  _stamp="$A2A_LIVE/.dnsverify"
  _now_s=$(date +%s 2>/dev/null)
  case "$_now_s" in ''|*[!0-9]*) _now_s=0 ;; esac
  _last=0
  [ -f "$_stamp" ] && _last=$(cat "$_stamp" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac

  if [ "$_old_iface" != "${_new_iface:-unknown}" ] || [ "${_old_vpn:-0}" != "$_new_vpn" ]; then
    log_to "$SUPLOG" "网络变化：iface=${_old_iface:-unknown}->${_new_iface:-unknown} vpn=${_old_vpn:-0}->$_new_vpn"
    rm -f "$A2A_LIVE/dns.aaaa" 2>/dev/null
    if dns_liveness_ok; then
      # 现有 DNS 还能用就什么都不动——开关 VPN 时服务端零感知
      printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
      printf '%s' "${_new_iface:-unknown}" >"$DNS_ACTIVE_CACHE" 2>/dev/null
      printf '%s' "$_new_vpn" >"$DNS_VPN_CACHE" 2>/dev/null
      log_to "$SUPLOG" "现有 DNS 仍然可用，保持不动"
      return 0
    fi
    log_to "$SUPLOG" "现有 DNS 已不可用，进入分级兜底"
  elif [ "$_iv" -gt 0 ] && [ "$_now_s" -gt 0 ] && [ $((_now_s - _last)) -lt "$_iv" ]; then
    return 0
  elif dns_liveness_ok; then
    printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
    return 0
  else
    log_to "$SUPLOG" "DNS 定期验活失败，进入分级兜底"
  fi
  printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
  dns_ensure
}

# gai.conf：ipv4_preferred=1 时保持 IPv4 优先。
# 为什么重要：手机常年双栈但 IPv6 常常只通一半（有地址没路由）。glibc 默认
# RFC3484 会先试 IPv6，连不通才回退 —— 每次都是 30 秒级别的超时。写
# `precedence ::ffff:0:0/96 100` 让 A 记录优先，出网立刻走 IPv4。
gai_apply() {
  [ -d "$A2A_LIVE" ] || mkdir -p "$A2A_LIVE" 2>/dev/null
  _pref=$(cfg_get ipv4_preferred 1)
  _have=0
  [ -r "$GAIFILE" ] && grep -q '^precedence ::ffff:0:0/96' "$GAIFILE" 2>/dev/null && _have=1
  if [ "$_pref" = "1" ] && [ "$_have" = "0" ]; then
    printf 'precedence ::ffff:0:0/96  100
' >"$GAIFILE.tmp" 2>/dev/null || return 1
    chmod 644 "$GAIFILE.tmp" 2>/dev/null
    mv -f "$GAIFILE.tmp" "$GAIFILE" 2>/dev/null || { rm -f "$GAIFILE.tmp"; return 1; }
    log_to "$SUPLOG" "gai.conf 已开启 IPv4 优先"
  elif [ "$_pref" != "1" ] && [ "$_have" = "1" ]; then
    # 注意：grep -v 在"一行都没剩下"时返回 1，如果写成 `grep -v ... && mv`
    # 就会把"删干净了"当成失败 —— 而我们的 gai.conf 恰好只有这一行，
    # 于是这个开关永远关不掉。用 sed 删除，判据只看 tmp 文件有没有生成。
    sed '/^precedence ::ffff:0:0\/96/d' "$GAIFILE" >"$GAIFILE.tmp" 2>/dev/null
    [ -f "$GAIFILE.tmp" ] && mv -f "$GAIFILE.tmp" "$GAIFILE" 2>/dev/null || { rm -f "$GAIFILE.tmp"; return 1; }
    log_to "$SUPLOG" "gai.conf 已关闭 IPv4 优先"
  fi
  chmod 644 "$GAIFILE" 2>/dev/null
  return 0
}

# 一次性把三个文件都准备好（安装时 / 开机时 / 手动刷新时调）
dns_bootstrap() {
  [ -d "$A2A_LIVE" ] || mkdir -p "$A2A_LIVE" 2>/dev/null
  chmod 755 "$A2A_LIVE" 2>/dev/null
  _rc=0
  dns_write "$@" >/dev/null 2>&1 || _rc=1
  nss_apply >/dev/null 2>&1 || _rc=1
  gai_apply >/dev/null 2>&1 || _rc=1
  return "$_rc"
}