# Agent2API 网关 · Magisk 模块（arm64）

把官方 `agent2api-server-linux-arm64.tar.gz` 里的服务端二进制直接跑在 Android 上：
面板 + OpenAI 兼容网关都跑在手机本机，开机自启、崩溃自动拉起、在线热更新。

* 面板 / 网关：`http://127.0.0.1:3065/` 、`http://127.0.0.1:3065/v1`
* 配置：`/data/adb/agent2api/env.sh`
* 数据：`/data/adb/agent2api/data`（SQLite、`account.key`）
* 日志：`/data/adb/agent2api/logs/`（`module.log` 守护日志、`server.log` 服务 stdout/stderr、`app.log` 应用自身日志）

> 两个版本号：**模块壳**（`module.prop` 里的 `v3.1.2`，指脚本与运行时）与
> **服务端载荷**（`rootfs/opt/agent2api/VERSION`，指上游二进制）本来就是独立的。
> 本包壳是 v3.1.2、内置载荷仍是 3.1.0 —— 这不是装错，`ctl version` 会分别列出。
> 想升载荷用 `ctl update`（在线热更新），不需要重刷模块。

## 为什么要这层壳

官方二进制是 **glibc** 的 Linux arm64 ELF，interpreter 写死 `/lib/ld-linux-aarch64.so.1`，
而 Android 只有 bionic —— 直接执行会报 `no such file or directory`（实际是找不到装载器）。
模块自带一套 Debian 12（glibc 2.36）运行时，并用 chroot 给它一个有 `/etc`、`/proc`、`/dev` 的私有根：

```
/data/adb/modules/agent2api/rootfs/          ← chroot 根（挂载后整体只读加固）
├── lib/            ld-linux-aarch64.so.1 / libc.so.6 / libm.so.6 / libgcc_s.so.1
│                   libresolv / libnss_dns / libnss_files / libnss_compat ...
├── bin/busybox     （占位，运行时把设备 busybox bind 进来，供可选降权用）
├── opt/agent2api/  agent2api-server + ui/（可被 /data 的在线更新层覆盖）
├── var/lib, /var/log, /tmp                  ← bind 到 /data 与 tmpfs
└── usr/share/zoneinfo  完整 tzdata（所有 IANA 时区名可用）
```

服务只读 rootfs、只写 `/data/adb/agent2api` —— 就算服务进程被攻破，
也改不了自己的二进制与 glibc 运行时；数据目录与模块包物理分离，刷模块不动数据。

## 日常

```bash
sh /data/adb/modules/agent2api/bin/ctl status      # 版本/进程/端口/健康一览
sh /data/adb/modules/agent2api/bin/ctl doctor      # 一键自检（只读，把各处判断收拢成清单）
sh /data/adb/modules/agent2api/bin/ctl restart     # 重启并做健康检查
sh /data/adb/modules/agent2api/bin/ctl log         # 守护日志（排障第一现场）
sh /data/adb/modules/agent2api/bin/ctl srvlog      # 服务 stdout/stderr
sh /data/adb/modules/agent2api/bin/ctl dns         # 重探 DNS 并显示 resolv.conf
sh /data/adb/modules/agent2api/bin/ctl clean       # 清回滚归档/暂存（保留最近 2 份）
```

排障顺序：`ctl doctor` → 看哪项 ✗ → `ctl log` / `ctl srvlog` 看现场 → `ctl restart`。

Magisk 模块页的「操作」按钮 = `restart` + 就绪轮询 + 状态回显（冷启动慢设备不再误报）。

## 在线更新（v3.1.1 新增，免重刷模块）

上游常规发版（新 provider、面板功能等）只动"服务端二进制 + ui/"，落在这个层面：

```bash
ctl update check          # 查 GitHub 最新版（仅查询）
ctl update                # 完整流程：下载 → sha256 校验 → 兼容性预检
                          # → 停机 → 数据快照 → 激活 → 健康验证（失败自动回滚）
ctl update install v3.2.0 # 指定 tag（配 AGENT2API_MIRROR 时绕过 API 直连下载）
ctl update drop           # 手动投放模式（见下）
ctl rollback              # 删掉更新层，回到模块内置版本（保留数据）
ctl rollback data         # 连升级前数据快照一起恢复
```

更新层就是 `/data/adb/agent2api/update/`（二进制 + ui + version 戳），
启动时 bind 覆盖进 chroot 的 `/opt/agent2api/`。要点：

* **预检先行**：激活前把新二进制临时 bind 进 chroot 试执行 `--version`，
  glibc 符号不满足或缺库会当场暴露（此时旧版还在跑，毫发无损）；
  这种"底座天花板"被顶到的情况会明确提示需要升级模块包，绝不会更新到起不来。
* **数据快照**：激活前把 `data/ + env.sh` 打包成 `backup/pre-update.tgz`。
  新版服务端会迁移 SQLite schema，**回滚必须连快照一起恢复**（`ctl rollback data`），
  否则旧二进制读不懂新 schema。
* **自动回滚**：激活后 120s 内 `/health` 不通，自动停用更新层、恢复快照、
  拉起内置版本，失败包归档在 `update.failed.<时间戳>/`。
* **手动投放模式**（shell 下载不可用时的保底）：手机浏览器从
  `github.com/Agent2API/agent2api/releases` 下载
  `agent2api-server-linux-arm64.tar.gz`（连同同名 `.sha256`）放进
  `/sdcard/Download/`，然后 `ctl update drop`，校验/预检/回滚走同一条流水线。
* 模块包自带的服务端版本更高时会自动停用旧更新层（升级仲裁），
  `ctl update` 前都会比对版本，不会装旧版。

**什么时候仍需要刷新版模块 zip**（预检会替你判断）：
glibc 运行时太老（上游新二进制要求更高符号版本）、新增了 rootfs 缺失的动态库、
模块自身脚本修复。其余一切上游更新都在线完成。

```bash
ctl backup            # data/ + env.sh 打包到 /sdcard/Download（随时手动备份）
```

## 手机端界面

官方 `ui/` 里本来就带两套，模块原样打包（v3.1.1 移除了上游残留的开发脚本 `ui/scanmobile.py`）：

* **桌面面板** `/` → `index.html`，窄屏时走 `css/mobile.css`（侧边栏变抽屉、表格变卡片）。
* **手机端** `/m`（也就是 `/m.html`）→ `m.html` + `m/mobile.js`（SPA）+ `m/mobile.css`，独立 PWA：
  `m/manifest.webmanifest` 里 `start_url=/m.html`、`display=standalone`、`orientation=portrait`，
  快捷方式直达签到 / 账号 / 请求日志。桌面面板侧边栏的「手机端打开」就是跳这里。

手机 Chrome 打开 `http://127.0.0.1:3065/m` → 菜单 → 添加到主屏幕，就是一个全屏 App；两套 UI 打的是同一份 `/api/*`，账号、Key、日志互通。

PWA 与 Service Worker 只在安全上下文注册：`127.0.0.1` / `localhost` 算安全，用 `http://<局域网IP>:3065` 打开时 SW 不注册 —— 页面照常能用，只是装不了 PWA、没有离线缓存。

## 让电脑上的客户端连上来

默认只监听 `127.0.0.1`（手机自己）。两条路：

**A. USB 转发（推荐，不暴露到局域网）**

```bash
adb forward tcp:3065 tcp:3065
# 电脑上 base_url = http://127.0.0.1:3065/v1
```

**B. 局域网直连**：`env.sh` 里改 `AGENT2API_HOST=0.0.0.0`，`ctl restart`，
手机和电脑同一 Wi-Fi，电脑直连 `http://<手机IP>:3065/v1`。

面板是明文 HTTP。**先在本机（127.0.0.1）完成管理员注册并建好网关 Key，再改成 0.0.0.0**：
面板的首次注册是开放的，在没有任何 Key/管理员的情况下对外监听，同一 Wi-Fi 下
任何人都能抢先注册成管理员（chroot 内 uid 0 = 整机 root）。这种组合模块会**拒绝启动**
并把原因写进 `/data/adb/agent2api/fatal`（`ctl status` 直接显示）。

## 稳定性设计（v3.1.1）

* **挂载 fail-fast**：数据/日志目录 bind 失败时拒绝启动（`$DATA/fatal` 留痕 + 系统通知），
  绝不把 SQLite 写进模块目录 —— 那种静默丢数据的事故在 v3.1.0 是可能的。
* **OOM 保护**：服务进程 `oom_score_adj=-900`（`AGENT2API_OOM_SCORE_ADJ` 可调）。
  v3.1.1 用的 `-1000` 是内核永不回收档 —— 网关这种长驻 + SSE + 缓存的进程一旦泄漏，
  内核只能去杀 `system_server` / 桌面，用户看到的是"手机莫名重启"。现在配 RSS 看门狗：
  每约 60s 看一次，连续 2 次超过阈值（默认物理内存 1/8，夹在 256~1024MB）就优雅重启。
* **健康探活**：自适应节拍 —— 连续成功逐步退到每 60s 一次（省电），一旦失败立刻回到
  每 10s 快速确认；连续失败约 3 分钟判假死自动重启（`AGENT2API_HEALTH_CHECK=0` 可关）。
  进程崩溃照旧分层退避重拉（3s/15s/60s/120s）。
* **日志轮转**：运行中轮询轮转（`server.log`/`app.log` 上限默认 16MB，`AGENT2API_LOG_MAX_MB` 可调），
  不再依赖"服务退出才轮转"。
* **DNS 自愈**：启动与每小时（按真实时间，不受轮询间隔影响）重探
  （props → `dumpsys connectivity` → 公网兜底）；检测到 IPv6 默认路由时 v6 DNS 会
  排到兜底序列最前（glibc 只消费前 3 个）。换网络后解析失败先等一个探针周期，
  不必再手动 restart。
* **崩溃通知**：异常退出 / 假死重启 / 拒启会发系统通知（`cmd notification post`，1 小时节流 1 条，ROM 不支持则静默）。
* **原子锁**：`mkdir` 锁根治双守护竞态（PID 文件互踩 / 双 server 抢端口）。

## 升级（模块本身）

在线更新覆盖不到的部分（glibc 运行时、脚本）才需要重刷新版模块 zip；
`/data/adb/agent2api` 不动，账号、Key、日志、在线更新层全保留。
升级不再覆盖你的停用状态：升级前 `ctl stop` 过的，升级后依然是停用的，想启用 `ctl start`。
（本包补丁：升级前正在运行的，升级后自动恢复自启，不再被安装器误停。）

## 自定义更新仓库（repo1 新增）

上游仓库被封/搬家时，把在线更新指到任意 GitHub 仓库（fork 或新家），解封后删掉配置即切回：

```sh
# /data/adb/agent2api/env.sh 里加一行（owner/name，或完整 https URL）
AGENT2API_REPO=somefork/agent2api
# 立即生效（ctl 每次执行都会重读 env.sh，无需 restart）：
sh /data/adb/modules/agent2api/bin/ctl update check
# 想切回默认仓库：删掉/注释 AGENT2API_REPO 那行即可
```

* `ctl update check` 会显示当前生效的仓库，便于确认切换成功。
* 目标仓库 Release 需提供同名资产 `agent2api-server-linux-arm64.tar.gz`（及 `.sha256`）。
* 版本仲裁仍生效：目标仓库版本号低于当前已装版本时拒绝"降级"，
  显式安装用 `ctl update install vX.Y.Z`；切回老仓库时同理。
* 手动投放通道（`ctl update drop`）不受仓库配置影响，任何来源的包都能走。

## 已知限制

* **账号只能走网页登录 / 手机验证码 / 粘贴凭证**。桌面端的「导入本机登录态」读的是
  Windows / macOS 客户端文件，Android 上没有那些客户端；AutoClaw / CatPaw / Accio /
  CodeArts / Trae 这类需要本机回调的网页登录在服务端形态下同样不可用。
* **DNS 由模块生成**：优先 `DNS_LIST`，其次 props / `dumpsys connectivity`，最后兜底
  223.5.5.5 / 119.29.29.29 / 8.8.8.8。glibc 最多用前 3 个 nameserver；纯 IPv6 网络下
  会把 2400:3200::1 顶到兜底序列最前。
* **在线更新的信任模型（重要）**：`ctl update` 的 sha256 和包来自**同一个 URL 前缀**，
  它只能防传输损坏，防不了恶意仓库/镜像；而 `AGENT2API_REPO` 可以指向任意 fork，
  预检阶段还会以 **root** 在 chroot 内**执行**这个二进制来读 `--version`。
  换句话说：**换仓库 / 装手动投放包 = 把整机 root 交给那个包的作者**。
  只从你信任的来源更新；`AGENT2API_UPDATE_ALLOW_UNVERIFIED=1` 更是完全放弃校验。
  （包内路径穿越已拦截：`../`、绝对路径、越界符号链接在解包前就会拒绝。）
* **TLS 根证书**：二进制用内置根（不依赖 `/etc/ssl`），模块仍附了 `ca-certificates.crt` 兜底。
* **在线更新下载通道**：优先 ROM `curl`、其次 Magisk busybox `wget`（TLS 能力看构建）；
  都不行就走手动投放模式 —— 校验与回滚逻辑对所有通道一视同仁。
* **后台存活**：Magisk 拉起的 root 进程不受 phantom process killer 管，但部分 ROM 的省电策略
  会掐网络；把 Magisk 与本模块加进电池白名单更稳。CPU 深睡会让进程内定时任务晚触发，
  唤醒后补跑 —— 这是所有常驻进程的物理限制，不建议用常驻 wakelock 换。
* **体积**：压缩包约 10MB（二进制 12MB + ui 5.8MB + glibc 运行时约 3MB + 完整 tzdata 0.6MB）。

## 卸载

Magisk 里移除模块并重启即可；`/data/adb/agent2api` 保留（账号、Key、日志、更新层都在），
需要时手动 `rm -rf /data/adb/agent2api`。

卸载会清掉 `disable` 与 `.installed` 两个标记：**卸载后重装 = 全新安装，服务正常自启**。
（v3.1.1 及以前不清这两个标记，重装后守护每次开机第一行就退出，`ctl status` 全是"未运行"，
重刷、重启都没用，只能手动 `ctl start` —— 这是 v3.1.2 修掉的一个状态机漏洞。）

## v3.1.4 变更记录：面板里直接升级服务端

**之前为什么不行**：服务端自更新是用 `rename(现行 → .backup)` + `rename(新 → 现行)` 换二进制的，
而模块把 `/opt/agent2api/agent2api-server` **bind 挂载**到了 `/data` 的更新层上 ——
bind 挂载点不能被 rename（EBUSY），面板只会得到一句"备份现行文件失败"。
另外模块还显式 `AGENT2API_SELF_UPDATE=0`，把面板的升级入口整个关掉了。

**现在**：

* `AGENT2API_SELF_UPDATE` 默认 **1**（`env.sh` 可改回 0）。面板「设置 → 软件更新」
  里能直接下载并安装新服务端，sha256 校验与 ui 替换都由服务端自己做。
* 去掉更新层的 bind：rootfs 的 `opt/agent2api` 就是运行版本，面板与 `ctl` 都直接写它。
  代价是重刷模块会把载荷退回出厂版本（重刷后重跑一次 `ctl update` 即可）。
* **守护补上"重启"这一环**：面板没有重启通道（那是 headless 容器入口才有的），
  所以守护每轮检查二进制的 `size+mtime`，一变就重启服务，并用新二进制自己的
  `--version` 刷新 `VERSION` 文件（否则 `ctl status` 会一直显示旧版本号）。
  从点「更新」到新版本生效，约 10 秒。
* `ctl rollback` 现在优先用面板留下的 `.backup`，其次用 `ctl update` 留的
  `payload-prev`；两者都没有时提示"重刷模块包回出厂版本"。

## v3.1.3 变更记录（真机回归修复）

**P0：模块在 KernelSU + toybox 0.8.13 上根本起不来 —— `/dev` 挂载方式整段重写。**

原来的做法是把宿主机的 `/dev/null`、`/dev/zero`、`/dev/random`、`/dev/urandom`
逐个 bind 到 rootfs 里的占位文件上。真机实测这条路走不通：

```
losetup: /dev/block/loop52=/dev/null: Invalid argument
mount: losetup failed
```

toybox 的 `mount` 在「源是字符设备、目标是普通文件」时会把它当成 loop 挂载去准备
回环设备，四个节点全失败；其中 `null` / `urandom` 是致命项，于是守护每轮都在
`mount_chroot` 里拒启，表现为「模块已装、服务从来没起来过」，日志只有一行
`FATAL: /dev/null bind 失败`，看不出是 toybox 的语义问题。
（对照实验：**目录 bind 正常**，只有「字符设备 → 普通文件」这一种组合坏。）

现在的做法：tmpfs 挂到 `$ROOT/dev`，再 `mknod` 出四个节点（`1:3 / 1:5 / 1:8 / 1:9`），
挂完做**可用性验证**（写 null、读 urandom 各一次）。tmpfs 不继承 `/data` 的 `nodev`，
节点直接可用，顺带避免把宿主设备节点暴露给 chroot。mknod 被 SELinux 拦时退化为
整目录 bind `/dev`（可用性优先，日志里明确写安全性下降）。

同时修的两处：

* **rootfs 只读加固**：`remount,bind,ro` 在 toybox 上直接失败。现在依次尝试
  `remount,bind,ro` → `remount,ro,bind` → `remount,ro` 三种写法，最终仍以
  「能不能写进去」这个写测试为准，不靠返回值下结论。
* **「操作」按钮不再只说「未运行」**：失败时直接把 `fatal` 的内容或 `module.log`
  末尾 8 行打印在按钮的输出里。v3.1.2 那个按钮点了没反应也不说为什么，是最差的体验。

## v3.1.2 变更记录（本补丁包）

修的全是"看起来在工作、其实已经坏了"的那类问题：

* **日志轮转改 copytruncate**：原来 `mv server.log server.log.1`，而写入方（服务进程）
  长期持有 fd，mv 只改目录项 —— 服务继续往 `.1` 里写、原路径消失、下一轮 `[ -f ]`
  直接返回，轮转**从第二次起永久失效**，`.1` 可以涨到几个 GB 吃满 `/data`。
  现在 copy + 原地截断，inode 不变、体积立刻归零。
* **rootfs 只读加固走两步法 + 写测试**：单次 `mount -o bind,ro` 在内核层会忽略
  `MS_RDONLY`（必须 `MS_REMOUNT|MS_BIND|MS_RDONLY` 二次调用）。toybox 不拆分的版本
  会**返回成功但仍是可写**，原代码于是跳过兜底、连告警都没有。现在只走两步法，
  并用"能不能写进去"这个唯一可靠判据验证。
* **停机加按 exe 扫描兜底**：升级模块时安装器用的是 `modules_update` 下的新 ctl，
  `$ROOT` 指向新目录，旧服务的 exe 路径永远匹配不上 → `stop_server` 以为没在跑，
  留下一个占着端口的孤儿。现在额外按「路径含 `rootfs/opt/agent2api/agent2api-server`」
  扫描，跨目录版本都能杀干净；pidfile 丢失的场景同时修好。
* **守护拉起加存活确认 + 双 fork 回退**：`setsid` 在调用者已是进程组组长时返回 EPERM，
  toybox 的 setsid 直接退出、不 exec 目标 —— 表现为"命令成功、守护没起来"，而调用方
  此时已经把 `disable` 删了，只能等下次开机。
* **内存看门狗 + `oom_score_adj` -1000→-900**（见"稳定性设计"）。
* **端口被占诊断**：3065 被别的应用占住时，服务 bind 失败 → 退避重启无限循环，
  日志里只有 `rc=1`。现在连续两次确认后写 `fatal` 标记停止重试，`status`/`doctor`
  直接显示占位 pid 和它的命令行。
* **卸载→重装不自启**（见"卸载"）。
* **空文件参与算术**：`restarts` / `last_notify` 是空文件时 `$(( + 1))` 在 mksh 下是
  致命错误，守护会**直接退出且不留日志**。
* **`/etc/localtime` 兜底 + 时区校验**：`TZ_NAME` 写错时 chrono 会退回 `/etc/localtime`，
  文件不存在就静默变 UTC，报表时间整体错 8 小时。
* **DNS**：resolv.conf 改为一次 `printf` 写入（原来 `: >` 清空后逐行追加，服务可能
  读到"只有注释行"的中间态）；IPv6 兜底原来固定排第 4 位，而 glibc 只消费前 3 个 ——
  是死代码，现在检测到 v6 默认路由时顶到最前。
* **更新包解包前审条目**：`../`、绝对路径、越界符号链接直接拒绝（`tar -C` 不防穿越）。
* **`ctl doctor` / `ctl clean`**：一键自检 + 清理回滚归档（原来 `.failed.*` 只增不减）。
* 其他：`proc_uptime` 解析 `/proc/<pid>/stat` 改为先剥 `(comm)`（comm 里有空格会整体错位）；
  健康检查工具链不再缓存"找不到 busybox"的失败结果；每小时 DNS 改为按真实时间；
  崩溃判定阈值 20s→45s（冷启动慢的机器会把正常重启误记成崩溃）；
  数据快照加体积上限（几百 MB 的请求日志会让 `ctl update` 卡在停机状态很久）；
  tmpfs 默认 256m→64m（tmpfs 吃的是 RAM）；更新包内同名二进制多于一个时记警告。

## v3.1.1-repo1 变更记录（上一版补丁包）

* 新增：`AGENT2API_REPO`（env.sh）自定义在线更新仓库，上游被封/搬家时切换、
  解封后删除配置即回默认仓库；`ctl update check` 显示当前仓库；
  API 返回 404 时给出换仓提示；仓库地址写错时回退默认并记日志。
* 修复：升级模块时安装器自身 `ctl stop` 落下 disable 标记，导致"运行中升级
  → 重启后服务静默停用"；现按升级前实际运行状态决定是否恢复自启。

## v3.1.1 变更记录

修复：数据/日志 bind 失败静默继续启动（丢数据风险）；升级覆盖用户停用状态；
`wait` 阻塞导致日志不轮转/DNS 不重探/假死不可检测；端口监听误报（不验监听者身份）；
双守护竞态；`exec` 未加引号；`/dev/tty` 无用 bind；`scanmobile.py` 残留；时区只有 2 个。

新增：在线热更新（免重刷模块）、rootfs 只读加固、OOM 保护、`/health` 假死检测、
崩溃通知、`ctl update/rollback/backup/health`、tmpfs 可配 256m、DNS 兜底增强。
