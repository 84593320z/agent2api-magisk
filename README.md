# agent2api-magisk

把 [Agent2API](https://github.com/Agent2API/agent2api) 的服务端跑在 Android 手机上（Magisk / KernelSU 模块），
外加一个改造过的手机端 APK：自动发现本机网关、功能开关与面板双向同步。

> 这是**个人修改版**，不是上游官方产物。服务端二进制与面板 UI 来自上游 Release，模块脚本与 APK 改造是本仓库的内容。

---

## 下载

最新构建在 **Releases** 页面（手机上直接点链接就能下）：

- [agent2api-magisk-v3.3.0-beta.7-arm64.zip](https://github.com/84593320z/agent2api-magisk/releases/download/v3.3.0-beta.7/agent2api-magisk-v3.3.0-beta.7-arm64.zip) —— Magisk / KernelSU 模块包（musl 静态载荷）
- [Agent2API-3.1.2-mod.apk](https://github.com/84593320z/agent2api-magisk/releases/download/v3.1.4/Agent2API-3.1.2-mod.apk) —— 手机端 APK

---

## 这一版（v3.3.0-beta.7 / magisk.31）改了什么

上一版（magisk.30）做了一次完整源码审计，19 项缺陷全部修掉并逐项复测。按影响排序：

**启动与守护**

1. `service.sh` 原来在括号子 shell 里跑整个启动流程，子 shell 继承的是**已经退出的父进程 PID**，`proc_start_ticks` 取不到启动代次 → 加锁直接拒绝；Magisk 又没有 boot-completed 钩子兜底，真机表现是"模块开着但服务不在"。现在改成 `setsid sh libexec/boot-start.sh` 独立进程，`$$` 是真身。
2. `stop_child` 先删 `server.pid / server.start` 再发信号：一旦杀不掉，外部再也认不出这个进程，日志里"保留 PID/启动代次"是假的。改成确认杀干净后才删，杀不掉时身份文件留着。
3. 快速崩溃熔断：原实现只要 `start_child` 成功就 `FAILS=0`，"起来 → 30 秒内崩 → 再起来"永远停在 1 次，3 次退避和 6 次熔断等于关掉。现在只有稳定运行 ≥120 s 才清零。
4. `keep_awake` 只有 `take_wake` 没有释放：热关自动启动 / 暂停 / 熔断三条路径都会留下 wake_lock。三条路径补 `release_wake`，运行期按配置按需释放。
5. 健康检查写死 `http://127.0.0.1`，而 `host` 可配置。新增 `svc_health_urls`：按配置归一化（`0.0.0.0`/`*`/`::` → 回环，`::1` 加方括号，局域网地址补回环兜底）。

**更新与回滚**

6. `payload_activate_staged` 在**健康检查之前**就 `rm -rf` 掉旧载荷，于是 `rollback_finish` 里"恢复旧目录"的分支永远空转，回滚只能报 `PREVIOUS-UNHEALTHY`。改成两阶段：切换时写 `run/update.pending` 标记保留旧目录，健康通过后由 `payload_commit_old` 提交删除；`sweep_stale_dirs` 认这个标记不误删。
7. 更新信号处理器 `upd_on_signal` 末尾是 `return 1`，回到 `upd_do_update` 继续装，还可能以 0 退出。改成 `exit 1` 真正终止顶层事务。
8. `svc_start` / `svc_stop` 里的 `trap 'exit 130' …` + `trap - HUP INT TERM` 会清掉调用方（`cmd_rollback` / `upd_do_update`）注册的事务处理器。删掉这层覆盖。
9. 自定义 `https://` 镜像被忽略：`mirror_url` 把配置当参数用（调用只传一个 URL），拼出来还是原地址。改成读一次 `github_mirror` 再拼前缀。
10. 版本比较 `better()` 先按 `.` 切分，`3.3.0-beta.10` 被切成 `3 / 3 / 0-beta / 10`，预发布号落到第四段，beta.10 与 beta.6 判等、`v3.x` 与 `v4.x` 也可能反序。改成先用 `-` 拆主版本与预发布段，再逐段按数字比。

**DNS**

11. `dns_liveness_ok` 用 `curl -sS -o /dev/null` 就算成功：HTTP 500、DNS 劫持页都当"可用"；`CURL` 缺失时还返回成功。改成缺 CURL 直接失败，`-f -w '%{http_code}'` 只认 200/204。
12. IPv6 可用性只看 main 表，Android 上 `default` 常挂在 per-netId 表里，判断偏保守。改成先查 `ip -6 route show table all default` 再退回 main。
13. `dns_apply_list` 用 `cp -f` 直接覆盖现役 resolv，写一半被中断就是半个文件；`dns_ensure` 全候选失败后只回填 nameserver，原文件的 `search` / `options` 丢失。改成 `mv -f` 原子替换，并在切换前整文件备份、失败整文件还原。

**安装、插件与打包**

14. 静态载荷（musl，无 `PT_INTERP`）仍被按 glibc 载荷校验，`payload_validate` / `loader_smoke` / 恢复逻辑 / 更新器全在找 `lib/ld-linux-aarch64.so.1`。新增 `payload_dir_is_static` 分流，静态载荷不再要求 loader/libc，更新器也不再往静态载荷里塞 glibc 库。
15. 插件解释器改写白名单把 `/apex/...`、`/system/bin/*linker64` 也算进去，会把 bionic 动态链接器改成 glibc 路径。白名单收紧成只放行 `ld-linux*.so*`。
16. 更新锁的 `reaping` 互斥由回收者创建，回收者崩溃后没人再回收，锁永久卡死。`ln reaping` 失败时读持有者身份，确认僵死就清掉重试。
17. `cfg_set` 用 `awk -v` 传值，awk 会把值里的 `\n` 当真换行——写成 `gateway_key=abc\nallow_no_key=1` 会多出一行 `allow_no_key=1`，等于凭空改配置。改用 `ENVIRON` 传值。
18. `install_cleanup` 只在 `_ZONE_COMMITTED=1` 时恢复时区库，而两次 `mv` 之间被打断正好没提交 → zoneinfo 整个丢失。改成只要旧目录还在就恢复；`post-fs-data.sh` 开机补一次 `zoneinfo.old.*` 回填。
19. `update-binary` 的 unzip 循环把命令拼成 `unzip unzip` / `busybox unzip unzip`，回退分支必然失败。改成分支拼装。

顺带修的两处小问题：`module_desc_set` 的 `sed` 替换串没转义 `&`/`|`；`pack.py` 的 `os.path.relpath(...).replace("\\\\", "/")` 匹配的是两个反斜杠，等于从未替换成功，重建 zip 时 `libexec/*` 会掉成 0644。

---

## 三个产物

| 产物 | 说明 | 怎么得到 |
|---|---|---|
| `agent2api-magisk-vX.Y.Z-arm64.zip` | Magisk / KernelSU 模块包（模块壳 + 内置服务端） | `python pack.py` → `dist/` |
| `Agent2API-3.1.2-mod.apk` | 改造过的手机端 APK | `apk-mod/` 里的流程（见下） |
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
  src/                 改动过的 6 个前端源文件
  a2a-mobile-mod.patch 对上游 desktop-tauri/mobile 的完整 diff
  repack.py            把重新构建的 Web 产物塞回官方 APK
  a2a-mod.jks          APK 签名密钥库（口令 a2a-mod-2026）
  README-mod.md        APK 侧的详细说明与验证记录
docs/                  审计 / 修复报告
test/run.sh            离线桩测试（不需要真机）
test/fix_verify.py     本次 19 项修复的逐项复测夹具（Windows + msys sh 下跑通）
pack.py                打包脚本（自动从 module.prop 取版本号）
```

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
adb uninstall com.agent2api.mobile     # 官方版签名不同，必须先卸
adb install -r Agent2API-3.1.2-mod.apk
```

首次启动会自动连上 `127.0.0.1:3065`。

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

- **APK 的硬件返回键会直接退出应用**。上游 Capacitor 8 的 `BridgeActivity` 不处理返回键，
  `@capacitor/app` 插件也没打进包；试过三种原生补丁均因 `Bridge.getWebView()` 返回 null 而失败。
  应用内左上角的 `‹` 返回是正常的。详见 `apk-mod/README-mod.md` 第 3.3 节。
- **cgroup 逃逸依赖设备**：只在 `/sys/fs/cgroup/cgroup.procs` 可写、且 `/proc/self/cgroup`
  里能匹配到 `apps`/`background` 等分组时生效；部分设备（cgroup v2 统一层级、厂商改写）不适用，属降级不影响运行。
- **Wi-Fi 判定只认 `wlan0/wlan1/swlan0` 的 IPv4**：纯 IPv6 网络或厂商自定义接口名会判成"不在 Wi-Fi"，
  `wifi_only=1` 时会被暂停。
- **本版没有真机回归**：19 项修复是在 Windows + msys `sh` 沙箱里用桩驱动源码函数验证的
  （`test/fix_verify.py`，21 项断言全绿），Android 侧仍需实机验证启动 / 守活 / 升级回滚。

---

## 构建

```bash
python pack.py          # → dist/agent2api-magisk-vX.Y.Z-arm64.zip
dash test/run.sh        # 离线桩测试，不需要真机
python test/fix_verify.py   # 19 项修复复测（需要 msys sh；会写 fixverify/ 沙箱）
```

APK 侧（需要 Node 20+，构建细节见 `apk-mod/README-mod.md`）：

```bash
cd desktop-tauri/mobile        # 上游仓库
npm ci && npx vite build --mode apk
python repack.py && zipalign -p -f 4 ... && apksigner sign ...
```

---
