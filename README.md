# agent2api-magisk

把 [Agent2API](https://github.com/Agent2API/agent2api) 的服务端跑在 Android 手机上（Magisk / KernelSU 模块），
外加一个改造过的手机端 APK：自动发现本机网关、功能开关与面板双向同步。

> 这是**个人修改版**，不是上游官方产物。服务端二进制与面板 UI 来自上游 Release，模块脚本与 APK 改造是本仓库的内容。

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
  customize.sh         安装脚本（首装判定、权限、时区兜底）
  service.sh           守护进程（开机拉起、崩溃重试、健康探活、看门狗）
  post-fs-data.sh      早期钩子
  action.sh            KernelSU/Magisk 的「操作」按钮
  uninstall.sh         卸载（清 disable/.installed，保留数据）
  bin/lib.sh           核心库（chroot 挂载、更新、DNS、通知…）
  bin/ctl              控制命令（status/doctor/update/rollback/clean…）
  config/default.env   默认配置模板
  rootfs/              chroot 根：Debian glibc + 服务端二进制 + 面板 UI
apk-mod/               手机端 APK 改造
  src/                 改动过的 6 个前端源文件
  a2a-mobile-mod.patch 对上游 desktop-tauri/mobile 的完整 diff
  repack.py            把重新构建的 Web 产物塞回官方 APK
  a2a-mod.jks          APK 签名密钥库（口令 a2a-mod-2026）
  README-mod.md        APK 侧的详细说明与验证记录
docs/                  审计 / 修复报告
test/run.sh            37 项离线桩测试（不需要真机）
pack.py                打包脚本（自动从 module.prop 取版本号）
```

---

## 快速开始

### 1. 装模块

```bash
# Magisk / KernelSU 里刷入 dist/agent2api-magisk-vX.Y.Z-arm64.zip，重启
sh /data/adb/modules/agent2api/bin/ctl status    # 看状态
sh /data/adb/modules/agent2api/bin/ctl doctor    # 一键自检
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
- **服务端载荷**：`module/rootfs/opt/agent2api/VERSION`（上游二进制）

`ctl version` 会分别列出。升级载荷有两条路：

```bash
sh .../bin/ctl update          # 模块侧：下载 + sha256 + 预检 + 备份 + 回滚
```
或直接在**面板「设置 → 软件更新」**里点更新（v3.1.4 起支持，守护会在 ~10 秒内自动重启生效）。

---

## 已知问题

- **APK 的硬件返回键会直接退出应用**。上游 Capacitor 8 的 `BridgeActivity` 不处理返回键，
  `@capacitor/app` 插件也没打进包；试过三种原生补丁均因 `Bridge.getWebView()` 返回 null 而失败。
  应用内左上角的 `‹` 返回是正常的。详见 `apk-mod/README-mod.md` 第 3.3 节。
- **rootfs 只读加固在部分设备上不生效**（toybox 忽略 `remount,ro`），`ctl doctor` 会给出 ⚠。

---

## 构建

```bash
python pack.py          # → dist/agent2api-magisk-vX.Y.Z-arm64.zip
dash test/run.sh        # 37 项桩测试，不需要真机
```

APK 侧（需要 Node 20+，构建细节见 `apk-mod/README-mod.md`）：

```bash
cd desktop-tauri/mobile        # 上游仓库
npm ci && npx vite build --mode apk
python repack.py && zipalign -p -f 4 ... && apksigner sign ...
```

---

## 说明

- 服务端二进制、面板 UI 来自上游 [Agent2API](https://github.com/Agent2API/agent2api) 的 Release，遵循其原始许可。
- 本仓库只包含模块脚本、APK 改造与文档。
- `apk-mod/a2a-mod.jks` 是自签密钥库（口令写在 `README-mod.md` 里），只用于本改造版 APK；
  私有仓库里放着方便重建，**不要用它签任何要公开发布的东西**。
