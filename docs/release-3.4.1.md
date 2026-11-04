# v3.4.1 / magisk.36 发布说明

本次迭代在 `f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4` 上合入复审修复，并同步上游 `aimod-cc/Agent2API v3.4.1`（`3ff4b8215d0d65c3451ca74923e90964ed7dbf59`）。

## 下载与版本

| 产物 | 下载 | 版本 |
|---|---|---|
| Magisk / KernelSU 模块 | [模块 Release](https://github.com/84593320z/agent2api-magisk/releases/tag/v3.4.1-magisk.36) | `v3.4.1 (magisk.36)` / `2026110436` |
| 手机端 APK | [APK Release](https://github.com/84593320z/agent2api-magisk/releases/tag/apk-v3.4.1-mod) | `3.4.1 / 30401`，`com.agent2api.mobile.mod` |

模块使用**官方 glibc 动态 AArch64 服务端**与现有随包运行库，不是 musl 静态构建。官方 server 与 256 个 UI 文件逐字节保留；loader 和 glibc 依赖闭包离线核验通过。

APK 从完整上游源码构建，融合自动发现、返回键、9 个网关开关以及读写一致性修复。延续原 mod 证书，证书 SHA-256：`d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`。

## 保留与加强的修复

- 事务恢复：payload/data 全部恢复成功才重启，失败保留 journal；快照与 txid 严格绑定，再次中断后可幂等恢复。
- 热安装与启动：孤儿进程清理、恢复失败阻断、安全 EXIT 重启门控。
- DNS：完整 iface/VPN/netid 身份绑定，成功验活后原子发布，发布故障保留旧数据。
- 前端：晚 GET 不覆盖 PUT，延迟 updater 内复检 epoch，写入只接受匹配 boolean 回显。

## 验收与安装

535/535 行为及集成回归、19 项 Shell 语法检查通过；模块两次打包 SHA-256 一致；APK v2 签名、17 项来源检查及 178 个 Web 资源逐字节核验通过。[完整验收报告与证据](upgrade-3.4.1/report.md)保留发布前历史状态；当前下载入口以本说明为准。Android 真机安装、运行、VPN 切换尚未实测。

1. 下载模块 ZIP，通过 Magisk / KernelSU 安装并按管理器提示重启。
2. 同证书 `com.agent2api.mobile.mod` 可覆盖升级；旧 `com.agent2api.mobile` 按[签名迁移说明](../apk-mod/release-migration.md)迁移。
3. 对附件执行 `sha256sum -c SHA256SUMS.txt`，清单中未下载的源码工件可按需要一并下载，或只核对对应安装包行。

模块 SHA-256：`7432e048860ffda1c53c994d6d2b5cc17f7175bffd5d8985da8a031f2fff5e10`。

APK SHA-256：`94a208b7699acf1224cd2fc36913f58e7cffaf055b9651bbf26e7f3e52a01f9e`。

## 源码与复现

```bash
python pack.py
NODE_BINARY=node PYTHONIOENCODING=utf-8 sh test/run.sh --full
python test/verify_upgrade_3_4_1.py
```

Release 的完整补丁针对上述仓库基线生成，包含此前复审修复；变更文件 ZIP、来源清单和独立回放验证结果同时附带。构建临时目录不进入源码，已归档的验收证据位于 `docs/upgrade-3.4.1/evidence/`。
