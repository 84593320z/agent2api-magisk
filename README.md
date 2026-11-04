# agent2api-magisk

把 [Agent2API](https://github.com/Agent2API/agent2api) 的服务端跑在 Android 手机上（Magisk / KernelSU 模块），
外加一个改造过的手机端 APK：自动发现本机网关、功能开关与面板双向同步。

> 这是**个人修改版**，不是上游官方产物。服务端二进制与面板 UI 来自上游 Release，模块脚本与 APK 改造是本仓库的内容。

---

## 下载

最新构建在 **Releases** 页面（手机上直接点链接就能下）：

- [agent2api-magisk-v3.4.0-magisk.35-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.4.0-magisk.35/agent2api-magisk-v3.4.0-magisk.35-arm64.zip) —— Magisk / KernelSU 模块包（v3.4.0 载荷 + 复审 RR-01..RR-12 修复）
- [agent2api-magisk-v3.4.0-magisk.34-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.4.0-magisk.34/agent2api-magisk-v3.4.0-magisk.34-arm64.zip) —— 上一构建（**存在已确认缺陷，勿用**，仅留作对照）
- [agent2api-magisk-v3.3.0-beta.7-magisk.33-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.3.0-beta.7-magisk.33/agent2api-magisk-v3.3.0-beta.7-magisk.33-arm64.zip) —— 上一版（magisk.33，融合 localfix-20261104），保留备用
- [Agent2API-3.4.0-mod.apk](https://github.com/84593320z/agent2api-magisk/releases/download/apk-v3.4.0-mod/Agent2API-3.4.0-mod.apk) —— 手机端 APK（v3.4.0 源码构建，自动发现 + 9 个功能开关；硬件返回键已修）
- [Agent2API-3.1.2-mod.apk](https://github.com/84593320z/agent2api-magisk/releases/download/v3.1.4/Agent2API-3.1.2-mod.apk) —— 上一代 APK（**硬件返回键会退出、自动发现判据不全，勿用**，仅留作对照）

---

## 这一版（v3.4.0 / magisk.35）改了什么

载荷仍是上游 v3.4.0，本版只修模块壳与工具链：按独立复审报告逐条修完 **RR-01..RR-12**。

- **事务/恢复**：回滚失败不再被 `|| printf` 吞掉（停服保现场、journal 记 `rollback-failed`）；按 journal 恢复前先取 update 锁；`customize` 热安装先停服再替换、装完自动拉起；数据换入判据改为 aside 存在性，不再「目标非空即完成」。
- **守护/DNS**：巡检补提交加健康门控（健康检查失败保留唯一回滚副本）；lastgood 与 `DNS_CACHE` 都绑定网络身份，跨网不沿用旧 LAN 解析器。
- **前端/工具**：开关页不再合并旧键（失败端点保持不可操作）；`repack.py` 拒绝同源输出并改原子替换；测试脚本 `posix()` 不再破坏 Linux 路径。
- **签名**：新增 `apk-mod/sign-tool.sh` / `signing.md`，泄露的旧证书指纹进黑名单；**旧包请勿再用**。

逐条根因、改法与负向验收见 [docs/fixes-v3.4.0-20261104/report-2.md](docs/fixes-v3.4.0-20261104/report-2.md)。

---

## 手机端 APK（v3.4.0-mod）

以前那个 `Agent2API-3.1.2-mod.apk` 是「官方 3.1.0 APK + 替换 `assets/public`」重打包出来的，
两个硬伤：`@capacitor/app` 没进包（硬件返回键直接退出应用）、web 资源与原生层版本对不上。

这一版改成**从上游 v3.4.0 源码完整构建**（Capacitor 8 + AGP 8.13 + JDK 21 + compileSdk 36）：

- 包名 `com.agent2api.mobile.mod`（与官方 `com.agent2api.mobile` 并存），`versionName 3.4.0`；
- 自动发现本机网关的判据改成**两段式**：`/health` 完整摘要 **或** `/api/panel/status`
  的 `{registered:boolean}` 信封 —— 手机模块的 headless 形态在未开「允许无 Key」时只回 `{"status":"ok"}`，
  只认第一段在真机上永远探不到自家网关；
- 设置页 9 个网关开关与桌面面板双向同步（5 秒回读 + 写串行 + 在途值不被覆盖）；
- 新钥匙签名（证书 SHA-256 `d0ca6713…b16f`），与泄露的旧钥匙无关；
- 源码补丁是 `apk-mod/a2a-mobile-mod.patch`（6 文件），可 `git apply` 到 `v3.4.0` 干净树后自行构建。

构建步骤、真机验证记录与已知限制见 [apk-mod/README-mod.md](apk-mod/README-mod.md)。

### 上游 v3.4.0 同步内容（magisk.34 起）

**同步上游 [aimod-cc/Agent2API](https://github.com/aimod-cc/Agent2API) v3.4.0 正式版**（上游 2026-11-03 发布）。

- 载荷 `seed/agent2api-server` + `seed/ui` 整体换成 **v3.4.0**：由 [84593320z/agent2api-musl](https://github.com/84593320z/agent2api-musl) CI 按上游 `v3.4.0` tag 构建的 musl 静态 arm64 包（无 `PT_INTERP`，解析器路径已等长改写为 `/data/a2a/resolv`）。
- `seed/VERSION` 同步为 `ver=3.4.0`；`module.prop` → `v3.4.0 (magisk.NN)`（当前 `magisk.35`），壳与载荷版本是对齐的。
- magisk.34 相对上一版的模块壳脚本（libexec 全家、安装器、守护）**零改动**——localfix-20261104 的全部修复原样保留；magisk.35 的脚本改动见上一节。
- 在线更新（`a2a update`）默认仍指上游官方 glibc 包；`seed/lib` 的 glibc 运行时保留不动，动态载荷升级路径依旧可用。

上游 v3.4.0 的主要变化（摘自上游 Release）：会话图片压缩、DeepSeek(dsh) 客户端接管、Trae 模型 ID 收敛（`-solo` 后缀迁移）、路由工作台模型筛选、插件安装等待在途请求、上游请求备用入口 + DNS 容错、更新检查诊断、账号存储快照缓存、阻塞线程池、豆包生图修复等 20 项。

> 从 musl 载荷包升级上来的用户：`a2a update`（在线升级）与面板更新都会走上游 glibc 包并自动分流到动态载荷模式，无需手动处理。

---

## 上一版（v3.3.0-beta.7 / magisk.33）改了什么

把 2026-11-04 交来的 `localfix-20261104` 覆盖包**融合**进仓库：R01–R19 全部保留（其中三处被加强），
另外补进一批事务与运行时能力（更新事务先停服+数据快照+txid 代次绑定、cgroup 全控制器逃逸、
boot-worker 统一开机入口、卸载零删除保护、DNS 三态还原、WebUI 全 DOM 渲染）。
逐条对照见 [docs/2026-11-04_localfix融合说明.md](docs/2026-11-04_localfix融合说明.md)。

> 输入包不是完整模块包（只有脚本与文档），处理方式是取其脚本、弃其安装器：脚本与文档合进 `module/`，
> 那份安装器存进 [overlay/](overlay/) 作参考，仓库的 `customize.sh`、`seed/`、`tools/`、`zoneinfo/`、`META-INF/` 保留。

验证：`test/verify_fixes.py` 37 项全绿、`test/verify_loop.py` 8 场景全绿、`sh -n` 全量 21 个 Shell 入口全过
（均无真机回归，详见上一版 tag 的 README）。

---

## 更早的版本

- **v3.3.0-beta.7 / magisk.32**：对 magisk.31 做独立复审（13 项真解决 / 6 项部分修复），
  修复复审查出的 R01–R19（6 高 / 11 中 / 2 低）：健康前删旧载荷、pending 写失败当成功、
  跨代误删、静态载荷五处硬失败、TERM 重入锁身份、cgroup/DNS/wake lock 等一整批。
  报告见 [docs/2026-11-03_Agent2API-magisk32-19组修复报告.md](docs/2026-11-03_Agent2API-magisk32-19组修复报告.md)。
- **v3.3.0-beta.7 / magisk.31**：完整源码审计，第一轮 19 项缺陷全部修复并逐项复测
  （启动子 shell PID、两阶段提交、版本比较、DNS 原子写、静态载荷分流等）。
  报告见 [docs/2026-11-03-源码审计-Agent2API-Android17.md](docs/2026-11-03-源码审计-Agent2API-Android17.md)。
- **v3.3.0-beta.6 / magisk.10–30**：早期版本，从 glibc 动态载荷过渡到 musl 静态载荷，
  历史细节见各 tag 的 README 与 `module/docs/`。

---

## 三个产物

| 产物 | 说明 | 怎么得到 |
|---|---|---|
| `agent2api-magisk-vX.Y.Z-magisk.NN-arm64.zip` | Magisk / KernelSU 模块包（模块壳 + 内置服务端） | `python pack.py` → `dist/` |
| `Agent2API-3.4.0-mod.apk` | 改造过的手机端 APK（v3.4.0 源码构建） | `apk-mod/README-mod.md` 的完整 gradle 流程 |
| `docs/*.md` | 审计报告与修复自查报告 | — |

---

## 目录

```
module/                模块源码（就是打进 zip 的东西）
  module.prop          壳版本 / 描述
  customize.sh         安装脚本（加锁、时区库原子切换、载荷安装）
  post-fs-data.sh      早期钩子（崩溃恢复、残留清理、bootstrap resolv）
  service.sh           开机入口：只负责把 libexec/boot-start.sh 拉成独立进程
  boot-completed.sh    KernelSU 的 boot-completed 钩子（Magisk 不触发）
  action.sh            KernelSU/Magisk 的「操作」按钮
  uninstall.sh         卸载（停服务、清锁、保留数据）
  hotinstall.sh        热安装
  libexec/             模块逻辑
    common.sh          路径与配置、日志、进程身份、锁、静态判定
    control.sh         启停、健康探活、端口、CLI 生成
    supervise.sh       守护主循环（退避、熔断、cgroup、wake_lock）
    payload.sh         载荷校验、安装、回滚、两阶段提交
    updater.sh         在线更新（镜像、校验、事务、信号）
    dns.sh             resolv / nsswitch / gai 生成、验活、回退
    plugin.sh          插件解释器改写
    launch.sh          载荷启动（静态直接 exec，动态走 loader）
    boot-start.sh      开机异步启动流程
    timezone.sh        时区兜底
    a2a                命令行入口（status/start/stop/update/rollback/dns/doctor…）
  seed/                随包的载荷（musl 静态 agent2api-server + 面板 UI + VERSION）
  tools/               curl、cacert.pem
  webroot/             KernelSU 状态卡（status.json / lastlog.txt）
  zoneinfo/            时区库（约 400 个区）
  settings.conf.example 配置模板
apk-mod/               手机端 APK 改造
  src/                 改动过的 7 个前端源文件（含新增组件/工具）
  a2a-mobile-mod.patch 对上游 desktop-tauri/mobile 的完整 diff
  repack.py            把重新构建的 Web 产物塞回官方 APK（参数化，不签名）
  sign-tool.sh         发布签名：生成新 keystore / 读指纹 / 拒绝已泄露的旧证书
  signing.md           旧私钥泄露的影响与「换钥匙」迁移步骤
  README-mod.md        APK 侧的详细说明与验证记录（含签名指南）
docs/                  审计 / 修复报告
  2026-11-03-源码审计-Agent2API-Android17.md   第一轮完整源码审计（19 项发现）
  fix-verification-2026-11-03.md              第一轮 19 项修复的逐项复测记录
  fix-verify-2026-11-03.json                  第一轮复测原始输出
  2026-11-03_Agent2API-magisk31-独立复审.md    独立复审：13 项真解决 / 6 项部分修复 + 19 组新问题
  2026-11-03_Agent2API-magisk32-19组修复报告.md 本轮按复审报告逐条修复的正式报告与复验证据
test/run.sh            离线回归入口：语法检查 + 事务故障注入 + 可选 Python 套件
test/txn_test.sh       事务/DNS/CLI 故障注入测试（journal 状态机、中断恢复、96 项断言）
test/fix_verify.py     第一轮 19 项修复的复测夹具（历史保留）
test/verify_fixes.py   本轮 R01–R19 函数级隔离复验（37 项断言，自动探测 sh，可用 A2A_SH 覆盖）
test/verify_loop.py    本轮 R01/R15/R16/R17 主循环集成复验（8 个场景）
pack.py                打包脚本（自动从 module.prop 取版本号，文件名带 magisk.NN）
```

两个复验脚本的中间产物（夹具、用例、原始输出）都写在各自的 `out/` 目录里，不进版本库。

---

## 快速开始

### 1. 装模块

```bash
# Magisk / KernelSU 里刷入 dist/agent2api-magisk-vX.Y.Z-arm64.zip，重启
su -c 'sh /data/adb/agent2api/bin/a2a status'    # 看状态
su -c 'sh /data/adb/agent2api/bin/a2a doctor'    # 一键自检
```

面板：`http://127.0.0.1:3065/`（首次进去注册管理员）。

### 2. 装手机端 APK

```bash
adb uninstall com.agent2api.mobile.mod   # 旧包/官方包签名不同，先卸干净
adb install -r Agent2API-3.4.0-mod.apk
```

首次启动会自动连上 `127.0.0.1:3065`；探不到就点「服务器 → 自动发现」或手填地址。

---

## 版本语义

两个版本号是**独立**的：

- **模块壳**：`module.prop` 的 `version`（脚本与运行时）
- **服务端载荷**：`module/seed/VERSION`（上游 musl 静态二进制）

`a2a version` 会分别列出。升级载荷有两条路：

```bash
su -c 'sh /data/adb/agent2api/bin/a2a update'
```
或直接在**面板「设置 → 软件更新」**里点更新（守护会在 ~10 秒内自动重启生效）。

> 载荷分两种：**静态**（musl，无 `PT_INTERP`，不依赖 glibc 与系统 DNS）和**动态**（glibc + 随包 loader）。
> 模块按 `payload_dir_is_static` 自动分流：静态载荷不要求 `lib/ld-linux-aarch64.so.1`。

---

## 已知问题

- **APK 只做到「构建 + 签名 + 包内容抽检」**：3.4.0-mod 是从上游源码完整构建的（`@capacitor/app`
  已进包，硬件返回键在代码层已修），但自动发现的新判据与返回键仍需一台装了模块的真机复验一次。
  详见 `apk-mod/README-mod.md` 第 3.2 / 3.3 节。
- **cgroup 逃逸依赖设备**：只在 `/sys/fs/cgroup/cgroup.procs` 可写、且 `/proc/self/cgroup`
  里能匹配到 `apps`/`background` 等分组时生效；部分设备（cgroup v2 统一层级、厂商改写）不适用，属降级不影响运行。
- **Wi-Fi 判定只认 `wlan0/wlan1/swlan0` 的 IPv4**：纯 IPv6 网络或厂商自定义接口名会判成"不在 Wi-Fi"，
  `wifi_only=1` 时会被暂停。
- **本版仍然没有真机回归**：修复是在 Windows + msys `sh` 沙箱里用源码切片 + 桩驱动验证的
  （`test/verify_fixes.py` 32 项、`test/verify_loop.py` 8 个场景，全绿），Android 侧仍需实机验证
  启动 / 守活 / 升级回滚。msys `sh` 不等于 Android BusyBox `ash`。

---

## 构建

```bash
python pack.py          # → dist/agent2api-magisk-vX.Y.Z-magisk.NN-arm64.zip
sh test/run.sh          # 离线回归：语法检查 + 事务/DNS/CLI 故障注入（不需要真机）
sh test/run.sh --full   # 上一行之外，追加 Python verify 套件（需要 python3）
```

`run.sh` 分三层：① 全部模块脚本的 `sh -n` 语法检查；② `txn_test.sh` 纯 POSIX
故障注入测试（更新事务 journal / 中断恢复 / 回滚失败保现场 / 恢复互斥 / sweep 保护 /
静态载荷 / DNS 网络身份与缓存恢复，共 96 项断言）；③ `--full` 时跑六组 Python 检查：
`verify_fixes.py`（R01–R19 函数级复验）、`verify_loop.py`（主循环集成复验 8 场景）、
`verify_paths.py`（跨平台路径转换）、`verify_frontend.py`（开关页状态合并）、
`repack_test.py`（APK 重打包的输入保护与原子输出）、`sign_test.py`（签名指纹拦截）。
`--full` 是验收模式：缺 python 或缺少套件文件都直接判失败，不会静默 SKIP。
Python 套件可用 `A2A_MODULE`、`A2A_VERIFY_OUT`、`A2A_SH`、`A2A_CURL` 覆盖路径，
中间产物写到 `test/*/out/`。

APK 侧（需要 Node 20+，构建细节见 `apk-mod/README-mod.md`）：

```bash
git clone https://github.com/aimod-cc/Agent2API.git && cd Agent2API
git checkout v3.4.0 && git apply /path/to/apk-mod/a2a-mobile-mod.patch
cd desktop-tauri/mobile
npm ci && npm install --no-save class-variance-authority clsx tailwind-merge tw-animate-css shadcn
mkdir -p android-www && npm run build:native && npx cap sync android
cd android && ./gradlew assembleRelease -PdevAppIdSuffix=.mod   # 需 JDK 21 + Android SDK 36
```

没有 Android SDK 时才退回 `repack.py`（官方 APK + 替换 `assets/public`，原生层插件缺失）。

---
