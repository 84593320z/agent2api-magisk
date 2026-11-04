# 2026-11-04 Agent2API v3.4.1 升级验收报告

## 结论

本地升级已完成：服务端与面板为官方 v3.4.1，模块版本为 `v3.4.1 (magisk.36)`，手机端为完整源码构建并签名的 `3.4.1 / 30401`。此前本地修复的事务、恢复、热安装、DNS 和前端一致性修复全部保留；升级后 **535 项行为/集成回归及 19 项 Shell 语法检查通过**。模块连续两次打包 SHA-256 一致，官方 server 与 256 个 UI 文件、10 个随包 glibc 文件和最终 ZIP 内容均完成逐字节核验。本轮交付为本地源码与安装产物，远端仓库和 Release 保持原状。

**载荷类型：官方 glibc 动态 AArch64，非 musl 静态包。** Windows 隔离 musl 构建遇到 host 临时目录与 MSYS 对象创建错误，失败中间产物未进入模块。选择官方动态包的原因是本仓库已有 loader 启动分支和 glibc 运行库，且本次实际 ELF 依赖检查通过。Android 安装、启动、热安装、VPN 切换与旧世代签名迁移没有真机执行记录，离线测试不冒充这些运行结果。

范围：[scope](<scope.md>)；过程：[timeline](<timeline.md>)；全部证据校验：[SHA-256](<evidence.sha256>)。报告 flavor=null；ATT&CK 不适用，本任务是软件升级与回归验收。

## 1. 基线与来源

| 对象 | 版本 / 来源 |
|---|---|
| 用户仓库基线 | `84593320z/agent2api-magisk`，`f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4` |
| 上轮修复 | 已验收 repair.patch；升级工作树含其全部修改 |
| 上游源码 | [aimod-cc/Agent2API v3.4.1](https://github.com/aimod-cc/Agent2API/tree/v3.4.1)，`3ff4b8215d0d65c3451ca74923e90964ed7dbf59` |
| 服务端官方归档 | [agent2api-server-linux-arm64.tar.gz](https://github.com/aimod-cc/Agent2API/releases/download/v3.4.1/agent2api-server-linux-arm64.tar.gz)，13,343,815 B |
| 官方归档 SHA-256 | `d494e333a697ca9b48f17fc84cd10abdbe5f113a2900aba372fdac3503971e1c` |
| server 原始字节 SHA-256 | `f26697fff3f34078b704f87f8aeb8fdaa17eaf132815106bd8fa399b9e084dac` |
| 模块版本 / versionCode | `v3.4.1 (magisk.36)` / `2026110436` |
| 手机包名 | `com.agent2api.mobile.mod` |
| 手机版本 | `3.4.1` / `30401` |

`seed/VERSION` 的 built 字段记录官方 Release 发布时间，而不是伪造本地编译时间。模块脚本通过现有 `payload_is_static` 分流，动态载荷由随包 `ld-linux-aarch64.so.1 --library-path` 启动。

## 2. 关键验收结论（Finding）

| Finding | 级别 | 状态 / 置信度 | 位置 / 证据 | 结论 |
|---|---|---|---|---|
| U01 载荷与 UI 同版本 | 信息 | 已完成 / 高 | [VERSION](<../../module/seed/VERSION>)；E01 | 257 文件与官方归档原字节一致，无旧 UI 残留；server 含 `agent2api/3.4.1` |
| U02 动态运行库闭包 | 信息 | 离线通过 / 高 | [launch](<../../module/libexec/launch.sh#L32-L41>)；E02 | 所有 DT_NEEDED、GNU version need、强版本化导入均能在 10 库闭包内解析；server 需 glibc 最高 2.34，随包 libc 提供至 2.36 |
| U03 Android DNS 路径 | 信息 | 离线通过 / 高 | [DNS](<../../module/libexec/dns.sh>)；E02/E09 | 现有 libc 的 `/data/a2a/resolv` 补丁保留，官方 server 未修改；本版无需对其做 musl resolver 字符串替换 |
| U04 此前修复完整保留 | 信息 | 已完成 / 高 | E04/E09 | payload/updater/customize/supervise/post-fs-data/DNS 六文件与修复树逐字节一致；535 项通过 |
| U05 手机端上游功能与改造融合 | 信息 | 已构建并离线通过 / 高 | E05–E08 | 新版 ToolsPage、附件等源文件保留，自动发现/epoch 屏障/严格回显修复保留；完整 native 构建与资源核对通过 |
| U06 安装包可重现与内容一致 | 信息 | 已完成 / 高 | E03 | 951 ZIP 条目，固定时间、执行权限、CRC、工作树字节对照通过；二次打包 SHA 一致 |
| U07 设备运行与远端发布 | 信息 | 本轮未执行 / 明确边界 | scope | 未 commit/push/发布；设备运行和旧签名资产处置另需实际执行记录 |

ELF 检查不等价于 Android 上的动态执行，也未将 unversioned 导入或运行时 dlopen 当成已观测行为。REA open_binary 确认 ELF/arm64/SHA；其 Windows 深度 provider 不支持本次 ELF，后续使用 pyelftools 解析精确结构与符号表完成兼容核验，未伪造反汇编结果。

## 3. 测试结果

| 套件 | 通过 |
|---|---:|
| 事务/DNS/CLI | 99 / 99 |
| DNS 完整身份 | 130 / 130 |
| 函数级修复 | 37 / 37 |
| 守护主循环 | 8 / 8 |
| 路径转换 | 10 / 10 |
| 恢复故障边界 | 25 / 25 |
| 前端真实函数/组件行为 | 182 / 182 |
| 前端集成 | 11 / 11 |
| 重打包保护 | 21 / 21 |
| 签名工具 | 12 / 12 |
| **合计** | **535 / 535** |

另有 19 Shell 语法检查；手机来源/快照 17/17；APK Web assets 178/178；APK v2 验签通过。符号链接重打包场景在此 host 不具备创建权限，原套件明确 SKIP，该项没有计入 21 个通过断言。日志保留原始混合编码字节及逐行 UTF-8/GB18030 解码派生文本，便于独立核对。

## 4. Evidence 台账

| Evidence | 覆盖内容 | source_ref | content_hash（SHA-256） |
|---|---|---|---|
| E01 | 官方二进制及 UI 来源清单 | [证据](<evidence/seed-manifest.json>) | `12d884627620fdc4680c99dad7c35954358dd698440c55d83050b8d0b90f0d53` |
| E02 | ELF 库依赖与版本化符号闭包 | [证据](<evidence/elf-compatibility.json>) | `bc9aeb151296e6835aafbed8a29ad33b716dd769989052b5496cc06737e2f371` |
| E03 | 模块 ZIP 字节/权限/CRC | [证据](<evidence/package-verification.json>) | `4a0dec14200e7e6a8853875ef9af86ba1e5dd0df52b8a1b30b1d88101aa3c65e` |
| E04 | 升级后全量回归 | [证据](<evidence/full-after-upgrade.txt>) | `c492efd2cf9ca3c67c4c5525044e4c461e612d7cb1eb15098f5cb93a3051afdc` |
| E05 | APK 版本与构建产物 | [证据](<evidence/apk-manifest.json>) | `efe239ccab5a8938c50133bbbe7ff9d40186d2d95bb22ab17418ed142f00ccc6` |
| E06 | 178 APK Web 资源逐字节核对 | [证据](<evidence/apk-assets-verification.json>) | `1886c7377cb6e86c49ee14bd69ad77e38dd7886c31bc34391beef184e5e2f40a` |
| E07 | APK 签名验签 | [证据](<evidence/apk-signature.txt>) | `86afcfa1499e3d3555443965f1b13656bad770e3da3b766ecfde86627cabd19b` |
| E08 | 上游与手机改造快照 17 项验证 | [证据](<evidence/mobile-source-verification.txt>) | `caa9c8a59e8b758074d90dc9a7307481aa42065d4c63a2485dfc2f05c0497ca3` |
| E09 | 前轮六个关键修复文件逐字节保留 | [证据](<evidence/repair-preservation.json>) | `5c9345add3c6eec6124d6541467bcf45b17b90a40017c6261119578ed6797278` |

所有 Evidence 类型均为本地制品/离线解析/源码函数测试，不包含 Android 真机观测。复现脚本：[ELF](<../../test/inspect_server_elf.py>)、[升级/ZIP 验证](<../../test/verify_upgrade_3_4_1.py>)、[手机来源](<../../apk-mod/verify-mobile-3.4.1.py>)、[APK 资源](<../../apk-mod/verify-apk-assets-3.4.1.py>)。

## 5. 验证路径（Path）

- **P01 来源 → 可用载荷**：官方归档 SHA（E01）→ ELF arm64/PT_INTERP/依赖与符号闭包（E02）→ server/UI 精确换入（U01/U02/U03）。
- **P02 修复 → 升级后保持**：旧修复树逐字节对照（E09）→ 新版二进制 VERSION 一致 → 535 项正负向故障测试（E04）→ U04。
- **P03 上游 mobile → 成品 APK**：上游提交/17 快照检查（E08）→ Web/Capacitor/Gradle 完整构建 → 178 资源字节对照（E06）→ 证书及版本检查（E05/E07）→ U05。
- **P04 源码 → 安装 ZIP**：module.prop → 两次固定元数据打包 → SHA 相同 → 全部成员/权限/CRC 对照（E03）→ U06。

## 6. 产物与安装

| 产物 | 大小 | SHA-256 |
|---|---:|---|
| [Magisk ZIP](<../../dist/agent2api-magisk-v3.4.1-magisk.36-arm64.zip>) | 20,168,888 B | `7432e048860ffda1c53c994d6d2b5cc17f7175bffd5d8985da8a031f2fff5e10` |
| [手机 APK](<../../upgrade-evidence/mobile/Agent2API-3.4.1-mod.apk>) | 5,880,005 B | `94a208b7699acf1224cd2fc36913f58e7cffaf055b9651bbf26e7f3e52a01f9e` |

模块通过 Magisk/KernelSU 选择上述 ZIP 安装。已有相同 mod 发布证书的 3.4.0-mod 可使用以下命令覆盖安装手机端：

```bash
adb install -r Agent2API-3.4.1-mod.apk
adb shell su -c 'sh /data/adb/agent2api/bin/a2a status'
adb shell su -c 'sh /data/adb/agent2api/bin/a2a doctor'
```

APK v2 RSA4096 证书 SHA-256：`d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`。旧包 `com.agent2api.mobile` 与当前 `.mod` 不是同一 applicationId；迁移/配置重建见 [release-migration](<../../apk-mod/release-migration.md>)。

## 7. 独立复现

在本仓库根目录：

```bash
python pack.py
python test/verify_upgrade_3_4_1.py
NODE_BINARY=E:/AI/tools/node/node.exe PYTHONIOENCODING=utf-8 sh test/run.sh --full
```

最后一条使用本机已验证的真实 Node 24.22.2 路径，其他环境通过 NODE_BINARY 指向其真实 Node。手机重构建需上游完整源码、Node/JDK/Android SDK，步骤见 [mobile README](<../../apk-mod/README-mod.md>)；其辅助脚本针对本地同级源码工作树，不假装单独 apk-mod 快照就是完整原生工程。

交付目录的 `agent2api-v3.4.1-upgrade.patch` 是相对于上述原始用户仓库基线的**完整二进制 Git 补丁**，包括此前修复和本轮升级；应用命令：

```bash
git checkout -b upgrade-v3.4.1 f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4
git apply --binary agent2api-v3.4.1-upgrade.patch
python pack.py
```

不要在已含相同 repair.patch 的工作树上再次叠加完整补丁。交付脚本用独立临时 Git 索引回放补丁并逐 blob 与工作树核对，不改主索引；单独 source-changes ZIP 包含变更文件及删除项 manifest。
