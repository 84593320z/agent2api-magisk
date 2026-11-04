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
DNS_NETID_CACHE="$RUNDIR/dns-netid"

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
    # 这里仅记日志；已发布 DNS 的身份只能由 dns_publish_cache 推进。
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
  # _DNS_LOCAL 只在 system/auto 采样的调用方赋值；static 兜底等路径
  # 不会设置它。显式 ${:-} 展开让 set -u 环境（回归测试）也不会中断。
  for _lu in ${_DNS_LOCAL:-}; do
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

  # 5) ROM 自带 resolv.conf 只作最后兜底（F-007：VPN 下禁止——它是底层
  # 物理网络的解析器，查询走直连路由会泄漏出隧道；与第 0 步“VPN 只认
  # 隧道自己的解析器”对齐）
  if [ "$_vpn" = "0" ] && [ -z "$_found" ] && [ -r /system/etc/resolv.conf ]; then
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

  _wid=$(dns_net_identity 2>/dev/null)
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
      # F-008：采样失败与「采到了但没有可用服务器」同样处理——统一落到
      # 下面的缓存恢复/静态兜底。旧实现两处都不恢复 live resolv：
      # 采样失败直接 return 1；采样成功但为空时 rm _tmp 后 return 0
      # （伪成功：live 文件缺失却报一切正常）。
      if ! dns_collect_system >>"$_tmp" 2>/dev/null; then
        : >"$_tmp" 2>/dev/null
      fi
      # 只有 auto 能保留最后可用配置，或使用静态地址作首次启动兜底。
      if ! awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_tmp" 2>/dev/null; then
        _dns_cache_hit=0
        if dns_cache_matches "$_wid" && awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$DNS_CACHE" 2>/dev/null; then
          # F-008：缓存有效时把缓存内容当采样结果，走正常发布路径（验证→
          # 去重→原子落盘→回写缓存）。旧实现 rm _tmp 后直接 return 0，
          # 只保住了“不写坏文件”，没恢复“live 文件缺失”：resolv 被删/断电
          # 残留时这个分支永远不会再写回任何内容，函数却报成功。
          if cp "$DNS_CACHE" "$_tmp" 2>/dev/null \
             && awk '$1=="nameserver" && $2!="" {ok=1} END {exit ok?0:1}' "$_tmp" 2>/dev/null; then
            _dns_cache_hit=1
            log_to "$SUPLOG" "暂时未取得活动网络 DNS；发布最后可用配置，不跳公共 DNS"
          fi
        fi
        if [ "$_dns_cache_hit" != "1" ]; then
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
  [ ! -d "$DNSFILE" ] && mv -f "$DNSFILE.new" "$DNSFILE" 2>/dev/null || {
    rm -f "$_final" "$DNSFILE.new" 2>/dev/null; return 1;
  }

  _want=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$_final" 2>/dev/null | head -n 1)
  _got=$(sed -n 's/^nameserver[[:space:]]*\([0-9A-Fa-f:.]*\).*/\1/p' "$DNSFILE" 2>/dev/null | head -n 1)
  if [ -z "$_got" ] || [ "$_want" != "$_got" ]; then
    rm -f "$_final" 2>/dev/null
    log_to "$SUPLOG" "警告：$DNSFILE 写入后内容不符（want=${_want:-none} got=${_got:-none}）"
    return 1
  fi
  dns_publish_cache "$_final" "$_wid" || { rm -f "$_final"; return 1; }
  rm -f "$_final" 2>/dev/null
  log_to "$SUPLOG" "DNS 已更新（mode=$_mode, identity=$_wid, 首选=$_got）"
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

# 缓存内容和完整身份在同一个文件里原子发布。三个旧路径只是已发布身份的
# 镜像，供 refresh 检测变化；绝不能把“刚观察到的网络”先写进这些路径。
# 子 shell 隔离辅助变量（本模块不依赖非 POSIX 的 local）。
dns_publish_cache() ( # $1=已成功写入的配置 $2=采样时的完整身份
  _pc_src=$1; _pc_id=$2
  [ "$(dns_net_identity 2>/dev/null)" = "$_pc_id" ] || return 1
  set -- $_pc_id
  [ "$#" = 3 ] || return 1
  _pc_if=$1; _pc_vpn=$2; _pc_net=$3
  _pc_stage="$TMPD/dns.publish.$$"
  mkdir "$_pc_stage" 2>/dev/null || return 1
  if ! mkdir "$DNS_CACHE.publish.lock" 2>/dev/null; then
    _pc_owner=$(cat "$DNS_CACHE.publish.lock/pid" 2>/dev/null)
    case "$_pc_owner" in ''|*[!0-9]*) rm -rf "$_pc_stage"; return 1 ;; esac
    if kill -0 "$_pc_owner" 2>/dev/null; then rm -rf "$_pc_stage"; return 1; fi
    # 上个发布者已退出，回收它的门闩后再竞争；cache 内容自带身份，不会洗白。
    rm -f "$DNS_CACHE.publish.lock/pid" 2>/dev/null
    rmdir "$DNS_CACHE.publish.lock" 2>/dev/null \
      && mkdir "$DNS_CACHE.publish.lock" 2>/dev/null || { rm -rf "$_pc_stage"; return 1; }
  fi
  trap 'rm -f "$DNS_CACHE.publish.lock/pid"; rmdir "$DNS_CACHE.publish.lock" 2>/dev/null' 0
  printf '%s' "$$" >"$DNS_CACHE.publish.lock/pid" || { rm -rf "$_pc_stage"; return 1; }
  _pc_saved=0
  # 先保存元数据的精确初始状态；目标是目录等异常时，发布尚未开始。
  for _pc_path in "$DNS_ACTIVE_CACHE" "$DNS_VPN_CACHE" "$DNS_NETID_CACHE"; do
    _pc_saved=$((_pc_saved + 1))
    if [ -e "$_pc_path" ]; then
      [ -f "$_pc_path" ] && cp -f "$_pc_path" "$_pc_stage/old.$_pc_saved" 2>/dev/null || {
        rm -rf "$_pc_stage"; return 1;
      }
    fi
  done
  # 缓存头是权威身份；旧缓存无头时只兼容完整且匹配的三个旧字段。
  if ! { printf '# agent2api-dns-identity %s\n' "$_pc_id" \
         && sed '/^# agent2api-dns-identity /d' "$_pc_src"; } >"$_pc_stage/cache" \
     || ! chmod 644 "$_pc_stage/cache" \
     || ! cp -f "$_pc_stage/cache" "$DNS_CACHE.new.$$" \
     || ! chmod 644 "$DNS_CACHE.new.$$"; then
    rm -f "$DNS_CACHE.new.$$"; rm -rf "$_pc_stage"; return 1
  fi
  printf '%s' "$_pc_if" >"$_pc_stage/new.1" \
    && printf '%s' "$_pc_vpn" >"$_pc_stage/new.2" \
    && printf '%s' "$_pc_net" >"$_pc_stage/new.3" || {
      rm -f "$DNS_CACHE.new.$$"; rm -rf "$_pc_stage"; return 1;
    }
  _pc_i=0; _pc_ok=1
  for _pc_path in "$DNS_ACTIVE_CACHE" "$DNS_VPN_CACHE" "$DNS_NETID_CACHE"; do
    _pc_i=$((_pc_i + 1))
    if ! cp -f "$_pc_stage/new.$_pc_i" "$_pc_path.new.$$" 2>/dev/null \
       || ! chmod 644 "$_pc_path.new.$$" 2>/dev/null \
       || ! mv -f "$_pc_path.new.$$" "$_pc_path" 2>/dev/null; then
      _pc_ok=0; break
    fi
  done
  # mv -T 不属于 POSIX；显式拒绝目录，避免 mv 把临时文件放进目录后报成功。
  if [ "$_pc_ok" = 1 ] && [ ! -d "$DNS_CACHE" ] \
     && [ "$(dns_net_identity 2>/dev/null)" = "$_pc_id" ] \
     && mv -f "$DNS_CACHE.new.$$" "$DNS_CACHE" 2>/dev/null; then
    rm -rf "$_pc_stage"
    return 0
  fi
  # cache 尚未提交：还原 metadata，不把失败候选伪记为新网络的已发布配置。
  _pc_i=0
  for _pc_path in "$DNS_ACTIVE_CACHE" "$DNS_VPN_CACHE" "$DNS_NETID_CACHE"; do
    _pc_i=$((_pc_i + 1))
    rm -f "$_pc_path.new.$$" 2>/dev/null
    if [ -f "$_pc_stage/old.$_pc_i" ]; then
      cp -f "$_pc_stage/old.$_pc_i" "$_pc_path.restore.$$" 2>/dev/null \
        && mv -f "$_pc_path.restore.$$" "$_pc_path" 2>/dev/null \
        || log_to "$SUPLOG" "DNS 身份元数据还原失败：$_pc_path"
    else
      rm -f "$_pc_path" 2>/dev/null
    fi
  done
  rm -f "$DNS_CACHE.new.$$"; rm -rf "$_pc_stage"
  return 1
)

# lastgood 同样将内容与身份装进一个原子文件；.id 仅保留给旧工具观察。
# 新格式读取不依赖 .id，旧格式仍要求匹配的 .id，避免 split 写入窗口。
dns_save_lastgood() ( # $1=已验证的 resolv $2=身份
  _lg_file="$A2A_LIVE/dns.lastgood"
  _lg_tmp="$_lg_file.new.$$"
  if ! { printf '# agent2api-dns-identity %s\n' "$2" \
         && awk '$1=="nameserver" {print $2}' "$1"; } >"$_lg_tmp" \
     || ! chmod 644 "$_lg_tmp" \
     || [ -d "$_lg_file" ] \
     || ! mv -f "$_lg_tmp" "$_lg_file"; then
    rm -f "$_lg_tmp"; return 1
  fi
  if ! printf '%s\n' "$2" >"$_lg_file.id.new.$$" \
     || ! chmod 644 "$_lg_file.id.new.$$" \
     || [ -d "$_lg_file.id" ] \
     || ! mv -f "$_lg_file.id.new.$$" "$_lg_file.id"; then
    rm -f "$_lg_file.id.new.$$"
    log_to "$SUPLOG" "lastgood 已原子记录完整身份，兼容 .id 镜像写入失败"
  fi
  return 0
)

dns_cache_matches() { # $1=当前完整身份；缺任一字段、跨 iface/VPN/netId 均拒绝
  [ -s "$DNS_CACHE" ] && [ ! -d "$DNS_CACHE.publish.lock" ] || return 1
  _cm_if=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null)
  _cm_vpn=$(cat "$DNS_VPN_CACHE" 2>/dev/null)
  _cm_net=$(cat "$DNS_NETID_CACHE" 2>/dev/null)
  [ -n "$_cm_if" ] && [ -n "$_cm_vpn" ] && [ -n "$_cm_net" ] || return 1
  [ "$_cm_if $_cm_vpn $_cm_net" = "$1" ] || return 1
  _cm_id=$(sed -n 's/^# agent2api-dns-identity //p' "$DNS_CACHE" 2>/dev/null)
  [ ! -d "$DNS_CACHE.publish.lock" ] || return 1
  [ -z "$_cm_id" ] || [ "$_cm_id" = "$1" ]
}

dns_apply_list() { # $1=候选；$2=trial 时只试写 live，验活通过后再提交缓存/身份
  _aid=$(dns_net_identity 2>/dev/null)
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
  chmod 644 "$_at" 2>/dev/null || { rm -f "$_at"; return 1; }
  # 必须是 rename 级原子替换。cp 直接覆盖会先把目标截断再写，
  # 正在读 resolv.conf 的解析器可能读到半截文件（nameserver 行被切断），
  # 表现就是随机解析失败。
  if ! cp -f "$_at" "$DNSFILE.new.$$" 2>/dev/null; then
    rm -f "$_at" "$DNSFILE.new.$$"; return 1
  fi
  chmod 644 "$DNSFILE.new.$$" 2>/dev/null || { rm -f "$_at" "$DNSFILE.new.$$"; return 1; }
  [ ! -d "$DNSFILE" ] && mv -f "$DNSFILE.new.$$" "$DNSFILE" 2>/dev/null || { rm -f "$_at" "$DNSFILE.new.$$"; return 1; }
  if [ "${2:-}" != trial ]; then
    dns_publish_cache "$_at" "$_aid" || { rm -f "$_at"; return 1; }
  fi
  rm -f "$_at" 2>/dev/null
  return 0
}

# 逐字节比对两个文件是否一致（还原后的读回校验用）。
# 优先 cmp；环境里没有 cmp 时退回 sha256_of（common.sh，多级兜底）。
# 两个哈希都算不出来时按“不一致”处理：宁可误报校验失败走降级路径，
# 也不能在没验证过的情况下宣布还原成功。
dns_file_same() { # $1 $2
  [ -f "$1" ] && [ -f "$2" ] || return 1
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
    return $?
  fi
  _dfs_a=$(sha256_of "$1")
  _dfs_b=$(sha256_of "$2")
  [ -n "$_dfs_a" ] && [ -n "$_dfs_b" ] && [ "$_dfs_a" = "$_dfs_b" ]
}

# 当前网络的解析身份：默认网卡 + VPN 状态 + netId。
# dns.lastgood 只是「某个网络上验证通过的配置」，换网后继续沿用就是拿
# 旧网络的解析器解析新网络的流量（wlan0 的 LAN DNS 在 tun0 下往往仍可直连，
# 等于把 VPN 的解析策略拆掉）。RR-06：lastgood 必须和身份绑定。
dns_net_identity() {
  _dni_if=$(dns_default_iface 2>/dev/null)
  case "$_dni_if" in ''|*[!A-Za-z0-9._:-]*) _dni_if="unknown" ;; esac
  _dni_vpn=0
  dns_vpn_active 2>/dev/null && _dni_vpn=1
  _dni_net=$(dns_active_netid 2>/dev/null)
  case "$_dni_net" in ''|*[!0-9]*) _dni_net="unknown" ;; esac
  printf '%s %s %s\n' "${_dni_if:-unknown}" "$_dni_vpn" "$_dni_net"
}

# DNS_CACHE 里可用的 nameserver：上一次验证通过、真正发布过的配置。
# dns_ensure 也必须读它（RR-07）——只让 dns_write 读缓存，等于生产入口
# 全都不恢复：supervise 启动与 dns_refresh_if_changed 走的都是 ensure。
dns_cache_list() {
  [ -s "$DNS_CACHE" ] || return 0
  awk '$1=="nameserver" && $2!="" {printf "%s ", $2}' "$DNS_CACHE" 2>/dev/null
}

dns_ensure() { # 分级兜底入口：任何调用点都可以直接用它替代 dns_write
  _emode=$(cfg_get dns_mode auto)
  if [ "$_emode" != "auto" ]; then dns_write "$_emode"; return $?; fi
  [ -d "$TMPD" ] || mkdir -p "$TMPD" 2>/dev/null
  _eid=$(dns_net_identity 2>/dev/null)
  _esys=$(dns_collect_system 2>/dev/null \
          | sed -n 's/^nameserver[[:space:]]*\([^[:space:]]*\).*/\1/p' \
          | awk '{printf "%s ", $1}')
  _esl=$(dns_static_list)
  # 采样跨过一次网络切换时整轮失败，不把前一个网络的样本绑定到后一个身份。
  [ "$(dns_net_identity 2>/dev/null)" = "$_eid" ] || return 1
  # 缓存是「上次发布成功」的副本，必须带上当时的网络身份才允许兜底：
  # 换到 VPN/别的 Wi-Fi 后，缓存里很可能是旧 LAN 的解析器，直接拿来用
  # 就是把流量指回原网络（RR-06 的同一个坑，换了个入口）。
  _ecache=""
  if [ -s "$DNS_CACHE" ]; then
    if dns_cache_matches "$_eid"; then
      _ecache=$(dns_cache_list 2>/dev/null)
    else
      log_to "$SUPLOG" "缓存里的 DNS 完整身份缺失或属于别的网络（当前 $_eid），不采用"
    fi
  fi
  _elgf="$A2A_LIVE/dns.lastgood"
  _elgid="$A2A_LIVE/dns.lastgood.id"
  _elgl=""
  if [ -s "$_elgf" ]; then
    _elg_identity=$(sed -n 's/^# agent2api-dns-identity //p' "$_elgf" 2>/dev/null)
    [ -n "$_elg_identity" ] || _elg_identity=$(cat "$_elgid" 2>/dev/null)
    if [ -n "$_elg_identity" ] && [ "$_elg_identity" = "$_eid" ]; then
      _elgl=$(awk '$1 !~ /^#/ {printf "%s ", $1}' "$_elgf" 2>/dev/null)
    else
      log_to "$SUPLOG" "上一条 lastgood DNS 属于别的网络（$_elg_identity != $_eid），本轮不采用"
      rm -f "$_elgf" "$_elgid" 2>/dev/null
    fi
  fi
  # 现役配置整文件留一份：四级都失败时原样写回，绝不把“还能凑合”的结果弄更糟。
  # 只记 nameserver 会把 search/options/注释全部丢掉，回滚反而更糟。
  _eback="$TMPD/resolv.orig.$$"
  rm -f "$_eback" 2>/dev/null
  # 初始状态分三种记录，候选全部失败时逐一精确还原（旧实现只认“非空”
  # 一种，原文件不存在 / 存在但为空这两种都会还原错）。
  _estate=absent
  if [ -f "$DNSFILE" ]; then
    if [ -s "$DNSFILE" ]; then
      _estate=file
    else
      _estate=empty
    fi
  fi
  # R14：备份失败就不能开始改。旧实现无视 cp 失败，一旦四级候选全部不可用，
  # 回滚只能走「仅回填 nameserver」的降级路径，search/ndots/注释会被整段丢掉。
  if [ "$_estate" = "file" ]; then
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
  # 候选顺序：身份匹配的 lastgood → 静态/系统 → 上次发布的可用配置 → 组合。
  # 缓存排在静态与系统之后：它可能是别的网络上的 LAN 解析器，只在前三级
  # 都拿不出东西时兜底（RR-07：没有它，采样为空 + live 缺失 + 无静态时
  # dns_ensure 直接失败，明明手里有一份验证过的可用配置）。
  if [ "$(cfg_get dns_follow_system 0)" = "1" ]; then
    _e1="$_elgl"; _e2="$_esys"; _e3="$_esl"; _e4="$_ecache"; _e5="$_esys $_esl"
  else
    _e1="$_elgl"; _e2="$_esl"; _e3="$_esys"; _e4="$_ecache"; _e5="$_esys $_esl"
  fi
  for _ecand in "$_e1" "$_e2" "$_e3" "$_e4" "$_e5"; do
    [ -n "$_ecand" ] || continue
    dns_apply_list "$_ecand" trial || continue
    if dns_liveness_ok && dns_publish_cache "$DNSFILE" "$_eid"; then
      # cache 已提交，lastgood 是可选加速记忆：失败保留旧原子记录并如实记日志。
      dns_save_lastgood "$DNSFILE" "$_eid" || log_to "$SUPLOG" "DNS 已发布，lastgood 原子记录失败，保留旧记忆"
      log_to "$SUPLOG" "DNS 生效并验证通过：$(printf '%s ' $_ecand)"
      # R14：成功也要收拾临时备份，否则每次 DNS 生效都往 tmp 里留一份整文件副本。
      rm -f "$_eback" 2>/dev/null
      return 0
    fi
  done
  # ---- 分级候选全部失败：按 _estate 精确还原初始状态。绝不能把最后一个
  # 失败候选留在 $DNSFILE 里还日志声称“保留现有配置”；每一步写操作都核对
  # 返回值，回写后读回比对（与备份逐字节一致 / 与预期状态一致）才算成功，
  # 校验失败只报错误日志并返回非零，不得报告成功。
  if [ "$_estate" = "file" ]; then
    if cp -f "$_eback" "$DNSFILE.restore.$$" 2>/dev/null \
       && chmod 644 "$DNSFILE.restore.$$" 2>/dev/null \
       && mv -f "$DNSFILE.restore.$$" "$DNSFILE" 2>/dev/null \
       && dns_file_same "$DNSFILE" "$_eback"; then
      # 所有候选失败：cache 与身份仍属于上一次成功发布，不从旧 live 重建。
      log_to "$SUPLOG" "DNS 分级兜底均未通过验活，已整文件还原原配置并校验一致（$(dns_probe)）"
    else
      rm -f "$DNSFILE.restore.$$" 2>/dev/null
      # 整文件还原失败（或还原后读回比对不符）：降级为仅回填原 nameserver。
      # 降级路径同样要核对结果，失败就如实报错，不能再说“保留现有配置”。
      if [ -n "$_eorig" ] && dns_apply_list "$_eorig" trial && [ -s "$DNSFILE" ]; then
        log_to "$SUPLOG" "DNS 分级兜底均未通过验活，整文件还原失败，已降级回填原 nameserver（$(dns_probe)）"
      else
        log_to "$SUPLOG" "DNS 分级兜底均未通过验活，整文件还原与降级回填均失败：$DNSFILE 可能残留失败候选，请人工检查"
      fi
    fi
    rm -f "$_eback" 2>/dev/null
    return 1
  fi
  if [ "$_estate" = "empty" ]; then
    # 原文件存在但为空：还原成空文件（tmp + mv 原子替换，读回校验为空）。
    _eempty="$DNSFILE.empty.$$"
    if : >"$_eempty" 2>/dev/null \
       && chmod 644 "$_eempty" 2>/dev/null \
       && mv -f "$_eempty" "$DNSFILE" 2>/dev/null \
       && [ -f "$DNSFILE" ] && [ ! -s "$DNSFILE" ]; then
      log_to "$SUPLOG" "DNS 分级兜底均未通过验活，已还原为初始的空配置文件"
    else
      rm -f "$_eempty" 2>/dev/null
      log_to "$SUPLOG" "DNS 分级兜底均未通过验活，还原空配置失败：$DNSFILE 可能残留失败候选，请人工检查"
    fi
    return 1
  fi
  # 初始状态：原文件不存在 → 删除候选留下的文件，还原“不存在”。
  if rm -f "$DNSFILE" 2>/dev/null && [ ! -e "$DNSFILE" ]; then
    log_to "$SUPLOG" "DNS 分级兜底均未通过验活，已删除候选文件，还原初始的不存在状态"
  else
    log_to "$SUPLOG" "DNS 分级兜底均未通过验活，删除候选文件失败：$DNSFILE 可能残留失败候选，请人工检查"
  fi
  return 1
}

# 每 2 分钟被 supervisor 调一次。变化就重来一遍兜底；没变化时按
# dns_verify_interval（默认 600s）抽检一次，避免每轮都发探测请求。
# 只在系统 DNS 变化时才重写，避免无意义的写盘
dns_refresh_if_changed() {
  [ "$(cfg_get dns_mode auto)" = "auto" ] || return 0
  # 只看「网卡/默认路由/VPN/netId」四项变化（ip + 一次 dumpsys 行），
  # 不再每轮跑完整 dumpsys 采样——那才是以前体感卡顿的来源。
  _old_iface=$(cat "$DNS_ACTIVE_CACHE" 2>/dev/null)
  _new_iface=$(dns_default_iface 2>/dev/null)
  [ -f "$DNS_VPN_CACHE" ] && _old_vpn=$(cat "$DNS_VPN_CACHE" 2>/dev/null) || _old_vpn=0
  _new_vpn=0
  dns_vpn_active && _new_vpn=1
  # F-007：同一张网卡上换网（Wi-Fi A→B、重关联）不会改 iface 名，只会换
  # netId。只比 iface/vpn 完全感知不到这类切换。
  _old_net=$(cat "$DNS_NETID_CACHE" 2>/dev/null)
  case "$_old_net" in ''|*[!0-9]*) _old_net="unknown" ;; esac
  _new_net=$(dns_active_netid 2>/dev/null)
  case "$_new_net" in ''|*[!0-9]*) _new_net="unknown" ;; esac

  _iv=$(cfg_get dns_verify_interval 600)
  case "$_iv" in ''|*[!0-9]*) _iv=600 ;; esac
  _stamp="$A2A_LIVE/.dnsverify"
  _now_s=$(date +%s 2>/dev/null)
  case "$_now_s" in ''|*[!0-9]*) _now_s=0 ;; esac
  _last=0
  [ -f "$_stamp" ] && _last=$(cat "$_stamp" 2>/dev/null)
  case "$_last" in ''|*[!0-9]*) _last=0 ;; esac

  if [ "$_old_iface" != "${_new_iface:-unknown}" ] || [ "${_old_vpn:-0}" != "$_new_vpn" ] \
     || [ "$_old_net" != "$_new_net" ]; then
    log_to "$SUPLOG" "网络变化：iface=${_old_iface:-unknown}->${_new_iface:-unknown} vpn=${_old_vpn:-0}->$_new_vpn netid=$_old_net->$_new_net"
    rm -f "$A2A_LIVE/dns.aaaa" 2>/dev/null
    # F-007：网络变化后不再走“现有 DNS 验活成功就保持不动”的捷径。
    # wlan0→tun0 之后旧 LAN 解析器往往仍可直连（等于绕过隧道的路由
    # 泄漏），旧逻辑却在此时把 recorded iface 换成 tun0、解析器一直用
    # LAN 的，VPN 的解析策略被静默拆掉。变化一律重算：VPN 下
    # dns_collect_system 只采经隧道可见的解析器，ROM 兜底也有 _vpn
    # 门控（见 dns_collect_system 第 5 步），与这里的语义一致。
  elif [ "$_iv" -gt 0 ] && [ "$_now_s" -gt 0 ] && [ $((_now_s - _last)) -lt "$_iv" ]; then
    return 0
  elif dns_liveness_ok; then
    printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
    return 0
  else
    log_to "$SUPLOG" "DNS 定期验活失败，进入分级兜底"
  fi
  # 检测不等于发布：ensure 成功后才推进身份和成功验活时间戳。
  if dns_ensure; then
    printf '%s' "$_now_s" >"$_stamp" 2>/dev/null
    return 0
  fi
  return 1
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