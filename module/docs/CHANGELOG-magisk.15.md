# magisk.21 —— 静态（musl）载荷自动适配

一旦上游（或自己的 fork）发布 `aarch64-unknown-linux-musl` 静态包，模块会自动认出来并：

- `launch.sh`：不再套 `ld.so --library-path`，直接 `exec` 载荷；
- `lib_verify()`：静态载荷没有 `$PLIB` 依赖，跳过校验。

判定：`payload_is_static()` 看二进制里有没有 `ld-linux*` 解释器路径字符串；
也可用 `A2A_STATIC=1/0` 强制指定。配合 magisk.20 的 `update_repo` / `update_asset`，
「自建 musl 包 + 自动更新」链路已打通。

---

# magisk.20 —— 为「上游根治」铺路

- `update_repo` / `update_asset` 变成可配置项（默认仍是上游官方仓库与 glibc 资产）：
  换 fork、换 musl 静态资产都不用改脚本，`.sha256` 依旧从同一 release 拉取，校验链路不变。
- 新增 `docs/upstream-musl-and-dns.md`：给上游的两条根治路线（DNS 环境变量 / musl 静态构建），
  含可直接照抄的代码片段与 CI 片段。

---

# magisk.19 —— 把「体感」对齐 wb2api / magpie

那两个模块之所以没这些事，是因为它们**根本不跟随系统 DNS**（wb2api 用 `WB2A_DNS`、
magpie 用 `DNS_LOCAL_HOSTNAMES`，都由自己的解析器直接读，程序自带的公网 DNS 固定不变）。
本版把同样的思路搬过来：

- **静态优先**：`dns_follow_system=0`（新默认）。解析顺序变成
  `上次可用 → 公网静态 → 系统采样 → 系统+静态`。公网 DNS 只要能通就一直用它，
  开关 VPN、切节点、Wi-Fi 换流量都**不再触发重写**。
- **变化只验活**：`dns_refresh_if_changed()` 检测到网卡/VPN 变化时，先发一次 95ms 的 204 探测；
  通了就只在日志记一行「现有 DNS 仍然可用，保持不动」并返回，一个字节都不改。
- **稳态不再跑 dumpsys**：原来每 2 分钟要跑 `dumpsys dnsresolver`(16ms) + `dumpsys connectivity`(31ms)
  去比对 DNS 有没有变，现在这项采样整个去掉，只有真要重建 DNS 时才跑。
- **IPv6 探测提速**：先看 `ip -6 route show default`（几十毫秒），没有 v6 默认路由就直接判定
  IPv6 不可用，不再先花 2 秒去 `curl -6`。这台机器实测从 2028ms 降到 ~25ms。

---

# magisk.18 —— 开关 VPN 的响应速度和日志噪声

- `dns_apply_list()`（`dns_ensure` 实际走的写文件路径）补写 `run/dns-active`、`run/dns-vpn` 两个缓存。
  之前只有旧的 `dns_write()` 写它们，导致 `dns_refresh_if_changed()` 永远认为「网络变了」，
  每 2 分钟白重写一次 DNS 并刷一行日志。
- `AAAA` 判定缓存（`/data/a2a/dns.aaaa`）改成只在网络真的变化时清空，不再每轮作废。
- 守护进程主循环每 30 秒做一次**轻量**探测（`ip route get` + `ip -o link`，不跑 `dumpsys`）：
  VPN 开关或默认网卡一变就立即重算 DNS，不必等 2 分钟的定期轮询。

---

# magisk.17 —— AAAA 被内核拦截导致「必须开 VPN」，已修

## 真机定位（OnePlus / Android 17 / KernelSU）

这台机器的内核直接拦掉了 **AAAA 查询**。用一个 18KB 的探针程序，手工构造 DNS 包发给同一台
解析服务器（192.168.3.1:53），结果：

| qtype | 结果 |
|---|---|
| A(1) | send 成功，正常拿到应答 |
| TXT(16) / MX(15) / HTTPS(65) | 全部 send 成功，正常应答 |
| **AAAA(28)** | **sendto 直接返回 EPERM（Operation not permitted）** |

glibc 的 `getaddrinfo(AF_UNSPEC)`（agent2api-server 与各插件都走它）会同时查 A 和 AAAA，
AAAA 这一腿失败就把整次解析报成 `EAI_AGAIN` = `Temporary failure in name resolution`，
于是所有上游请求全灭。而模块自带的 curl 用的是 c-ares（不看 AAAA），所以「a2a doctor 全绿、
应用却全挂」。开 VPN 能用的原因是走了 Clash 出口，请求根本不在本机做 DNS。

## 修法

glibc 2.36 支持 `options no-aaaa`（`RES_NOAAAA`）：加上之后 AAAA 不再发出，
`getaddrinfo(AF_UNSPEC)` 只拿 A 记录，AAAA 变成 `EAI_NODATA` 而不再拖死整体解析。
实测同一份配置加上 `no-aaaa` 后，AF_UNSPEC 立刻能取到 IPv4 地址。

- 新增 `dns_no_aaaa=auto`：`auto` 用自带 curl 探一次 IPv6（6 秒超时），不通就写 `no-aaaa`；
  判定缓存 3 小时，网络切换（`dns_refresh_if_changed`）时自动作废重测。
- `dns_apply_list` / `dns_write` / `post-fs-data.sh` 三处 `options` 行统一改由 `dns_opts_line` 生成。
- 开机早期（post-fs-data）只读缓存不探测，避免无网时误判成 IPv4-only。

---

# magisk.16 变更说明（相对 magisk.14 原版）

    > 只改脚本层。`seed/agent2api-server`（服务端本体）、`seed/lib`（glibc）、`tools/curl`
    > 一个字节都没动，所以上游 `a2a update` 依旧能用官方 sha256 校验通过，
    > 也依旧可以把模块目录整个换回官方版本。

    ## 一、DNS（"必须挂 VPN 才能用"的根因）

    | # | 位置 | 改动 |
    |---|---|---|
    | 1 | `libexec/dns.sh` | 新增 `dns_liveness_ok()` / `dns_apply_list()` / `dns_static_list()` / `dns_ensure()`：四级兜底（上次可用 → 系统采样 → 采样+静态 → 纯静态），每级写完立刻用自带 curl 打一次 204 验活，通了就停并记住；四级全废则把原配置写回，绝不写空 |
    | 2 | `libexec/dns.sh` | `dns_refresh_if_changed()` 加抽检：配置没变也让 `dns_verify_interval`（默认 600s）验一次活，坏了就地自愈 —— 原来"写歪一次就永久歪" |
    | 3 | `libexec/dns.sh` | 全链接受 IPv6（原正则只认 v4，v6-only / DNS64 网络直接死） |
    | 4 | `libexec/dns.sh` | `dns_vpn_active()` 不再裸 grep `VPN`（假阳性），改用 `ip -o link` 看网卡状态，`ip` 不在才退 `dumpsys` |
    | 5 | `service.sh` / `boot-completed.sh` / `hot-restart.sh` / `supervise.sh` | 四处启动路径统一走 `dns_ensure`（启动那次就验活） |
    | 6 | `post-fs-data.sh` | 开机第一份 resolv.conf 改成尊重 `dns_static`，并带 v6 |

    ## 二、启动 / 守护

    | # | 位置 | 改动 |
    |---|---|---|
    | 7 | `libexec/common.sh:net_ready()` | 原来只 grep main 路由表（Android 上常年空）→ 开机必空等满 45s。改成 `ip route get` + 全表默认路由 + 有全局地址三级判据 |
    | 8 | `libexec/launch.sh` | 时区初始化失败原来是 `exit 1`（服务永远起不来），改成告警降级 |
    | 9 | `libexec/supervise.sh` | 主循环每轮重读端口，不再用启动时的快照判断占用 |
    | 10 | `service.sh` | `wait_net` 超时写日志，不再静默 45s |
    | 11 | `libexec/common.sh:sweep_stale_dirs()` | 补清 `payload.incomplete/broken/interrupted/rollback.failed` 等 5 类残留 |

    ## 三、事务 / 升级

    | # | 位置 | 改动 |
    |---|---|---|
    | 12 | `customize.sh` | 清 `payload.new.*` 挪到拿到 `update.lock.d` 之后（原顺序会删并发事务的 staging） |
    | 13 | `customize.sh` | 报成功前 `sync`，避免"装完重启又变回旧载荷" |
    | 14 | `libexec/payload.sh` | 切换成功后 `live_link_refresh` 失败只告警，不再把已成功的切换判成失败 |
    | 15 | `libexec/updater.sh` | `api.github.com` 直连失败时允许用镜像再拉一次版本列表（`update_mirror_api=1`）；包体与 sha256 仍强制官方 |

    ## 四、体验 / 性能

    | # | 位置 | 改动 |
    |---|---|---|
    | 16 | `libexec/common.sh:rotate_log()` | 归档改用 `tail -c`，只留尾部 N KB，不再整份 cp 8MB |
    | 17 | `libexec/plugin.sh` | `interp_fix` 保留原权限位（不再一律 755）；插件 `bin` 目录扫描改 `find` |
    | 18 | `libexec/control.sh` | 健康检查去掉多余的 `--cacert` |
    | 19 | `libexec/a2a` | `status` 的时区行不再恒显示"跟随系统"；`dns probe` 探针换国内可达地址 |
    | 20 | `libexec/common.sh:local_ip()` | 排除 `198.18/198.19` fake-ip，局域网地址不再指向 TUN 占位网段 |
    | 21 | `supervise.sh` + `webroot/` | 新增 `status.json` / `lastlog.txt`，模块 WebUI 页 5 秒轮询实时状态；模块卡片描述同步运行态 |
    | 22 | `action.sh` | [执行] 按钮：没跑就启动 → 健康检查 → 直接打开面板 |

    ## 回滚

    模块管理器的"卸载"不会删 `/data/adb/agent2api`（`purge_on_uninstall=0`），
    所以想退回官方版：重新刷入官方 magisk.14 包即可，配置与数据都在。
    
---

## 附：magisk.16 追加（借 wb2api v1.4.4 的三处补齐）

| # | 文件 | 改动 | 来源/理由 |
|---|---|---|---|
| 23 | `libexec/common.sh` | `local_ip()` 重写：ifconfig 兜底同时认 `inet 1.2.3.4`（玩具箱）与 `inet addr:1.2.3.4`（老 ROM），且正则要求 `inet` 后跟空格，避免把 `inet6 fe80::` 取成 `6` | wb2api `lib.sh` 的两条 sed 分支就是这么写的；原实现只认 `addr:`，现代 Android 上等于没有兜底 |
| 24 | `libexec/common.sh` | `local_ip()` 不再回落到 `rmnet/ccmni` 蜂窝口，也过滤掉所有 `rmnet*|ccmni*|tun*|ppp*|wg*`；拿不到局域网地址就返回空 | wb2api 注释直说"取到 10.100.x.x 反而误导"；蜂窝地址在运营商 NAT 后，同一 Wi-Fi 的电脑连不上 |
| 25 | `libexec/updater.sh` | `upd_curl` 三级降级：自带 curl → 系统 curl → busybox wget；只有 126/127（跑不起来）才降级，网络错误照原样上报 | wb2api `updater.sh` 的下载候选链；静态 curl 被清理工具删掉时，在线升级不该整条死掉 |

> 另外三条只学了思路、没改代码：模块说明实时写运行状态（magisk.15 已有）、状态文件 + 轮询（已有）、卸载先杀看门狗再杀网关（已有）。

## magisk.22 —— 换成自建 musl 静态载荷（本次最大改动）

- `seed/agent2api-server` 换成 **本机交叉编译的 aarch64 musl 静态二进制**（`rustup stable-x86_64-pc-windows-gnu` + `aarch64-unknown-linux-musl` target + zig 0.17 作为 C 交叉编译器，`-C link-self-contained=no`；无 PT_INTERP，14,254,176 字节）。
- 二进制内 `/etc/resolv.conf`（16 字节）**等长改写**为 `/data/a2a/resolv`（16 字节），保留模块的私有 resolv 路径机制，但**不再需要 glibc 动态加载器**。
- 由此彻底消失的依赖：`/data/a2a/ld.so` 软链接的时序问题、`lib_verify`/`lib_restore`、插件 `PT_INTERP` 改写（对插件仍保留，对主载荷不再需要）、`LD_LIBRARY_PATH` 指向 payload/lib 的解析链。
- musl 自带的 resolver 直接读 `/data/a2a/resolv`，**不再走 glibc 的 NSS/nsswitch/gai.conf 三件套**，因此 magisk.17 引入的 `no-aaaa` 仍然有效（musl 也会读 `options`），但对 IPv6 的影响面更小——musl 只在本机确实需要 v6 时才发 AAAA。
- `seed/lib/` 全部保留，用于兼容官方 glibc 载荷（`a2a update` 换回官方包时仍能跑）；`payload_is_static()` 会自动判断走哪条启动路径。
- 卸载脚本、DNS 分级兜底、状态卡、镜像升级等前序改动全部继承。

## magisk.23 修静态载荷下的自我识别

- `libexec/control.sh` 的 `pid_is_server()`：原来要求 cmdline 里出现带前导空格的 payload 路径，那是 `ld.so --argv0` 启动方式的特征。换成 musl 静态载荷后内核 cmdline 直接以绝对路径开头、没有前导空格，导致身份校验失败 → `a2a doctor` 报「联合健康检查尚未通过」、端口归属显示「pid=未知」、supervisor 只能进 `running-unverified`。
- 修法：取到 cmdline 后先统一包一层空格（`_cl=" $_cl "`），两种启动方式都能整词匹配；身份校验不放松——仍然要求出现本模块 payload 的完整路径。

## magisk.24 让在线升级在「下载域名被墙」的网络里也能跑

- `libexec/updater.sh`：官方 `.sha256` 拉取失败时，若 `update_sha_via_mirror=1`，允许用**同一个镜像**再取一次。实测这台机器 `api.github.com` 通（200）、`github.com` 超时（000）、`gh-proxy.com` 通，所以包体只能走镜像；原来的实现卡在「官方 sha256 下载失败，拒绝用镜像自证完整性」，整条更新链死在这里。
- 安全口径没放松：镜像同时承载 tar 与 sha 时，信任边界与「tar 走镜像 + sha 走官方」是等价的 —— 想更严格就关掉这个开关、改用 `update_pin=<固定 digest>`。
- `settings.conf.example` 新增 `update_sha_via_mirror=0`（默认关，保持原有严格行为）。

## magisk.25 载荷换成构建仓库的 CI 产物

- `seed/agent2api-server` 与 `seed/ui` 直接取自 `84593320z/agent2api-musl` 的 Release 产物（CI 编译 + 等长改写解析器路径），验证「构建仓库 → 手机」这条链的产物可用性。
- 该产物 14,245,528 字节、aarch64、无 PT_INTERP。

## magisk.26 下载策略与本地包更新

- `upd_download()` 改成**先直连、失败再走镜像**。原来只要配了 `github_mirror`，所有下载永远走镜像 —— 挂了 VPN 也照样走镜像，等于白挂（实测镜像 24~85KB/s，PC 直推 16MB/s）。
- 新增 `a2a update --file <tar.gz> [--sha <hex>] [--tag vX.Y.Z]`：直接吃本地包，跳过下载；sha256 校验、tar 安全检查、事务切换、健康检查、失败回滚全部照旧。
- 日常升级推荐：PC 下载 → `adb push` → `a2a update --file /data/local/tmp/x.tar.gz --sha <hex>`，秒级完成且可回滚。

## magisk.27 版本号归一

- `upd_latest_tag()` 返回的 tag 带 `v`（`v3.3.0-beta.6`），而 `payload_version()` 读到的 `seed/VERSION` 不带（`3.3.0-beta.6`）—— 两者直接比较永远不相等，于是「已经是最新版本」这个闸门从来没生效过，每次都会重新下载一遍。
- 修法：取出 tag 后统一算出 `_ver="${_tag#v}"`，比较与写入 `VERSION` 都用它；本地包更新时把用户给的标签补上 `v` 前缀再走校验。

## magisk.28 模块卡片文案刷新

- 真机现象：服务在跑，管理器卡片却停在「已停止 · 端口 3065 · 载荷 3.3.0-beta.6」。
- 根因：`module_desc_set()` 不管 `ksud module config set` 成没成功，都会往下写 `run/desc.last`；更新流程里 `svc_stop` 那一下写了「已停止」之后，紧接着的重启恰好碰上 ksud 忙/失败，于是 `desc.last` 记住了「已停止」，之后每轮都因为"文案没变"直接 return，永久卡住。
- 修法：① 只有写成功才更新 `desc.last`，失败留 `run/desc.pending` 标记下一轮重试；② 同时直接改模块目录的 `module.prop`（管理器读的就是它，magpie 的老办法），不再单押 ksud；③ 新增 `a2a desc [文本]`，可手动强制刷新一次。

## magisk.29 修 a2a desc 的空字段

- `a2a desc` 手动刷新时会打出「载荷  · 面板 3065」—— `payload_ver()` 定义在 `libexec/payload.sh`，而 `a2a` 只在 status/doctor 里 source 它。`cmd_desc` 里补上 source，并给 `payload_ver` 加 `?` 兜底。
- 另外记录一条实测结论：`ksud module config set override.description` 只在**模块上下文**里可用，从 `a2a` 这种普通 root shell 调用会报 `This command must be run in the context of a module or passed --internal <name>`；所以卡片文案必须以 `module.prop` 为主、ksud 为辅（magisk.28 已这么改）。

## magisk.30 再修 a2a desc 的载荷字段

- `payload_ver()` 定义在 `libexec/supervise.sh`（只有 supervisor 会加载），`a2a` 里应当用 `libexec/payload.sh` 的 `payload_version()`。magisk.29 用错了函数，于是打出「载荷 ?」。
