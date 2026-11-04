# APK Release 迁移说明（供维护者同步发布正文）

本文是本地发布正文模板，不代表远端 Release 已经更新。本轮已从完整 v3.4.1 源码重建
[Agent2API-3.4.1-mod.apk](../upgrade-evidence/mobile/Agent2API-3.4.1-mod.apk)，包含写屏障、严格回显及 epoch 修复；
实际包名 `com.agent2api.mobile.mod`，versionName `3.4.1` / versionCode `30401`，复用既有新证书并通过 APK v2 验签。
最终 SHA-256 见 [APK manifest](../upgrade-evidence/mobile/apk-manifest.json)。本次没有远端发布或真机验收。

## 用户必须执行的迁移

旧正式 APK 虽名为 `Agent2API-3.1.2-mod.apk`，实际包名为 **`com.agent2api.mobile`**，
其签名私钥已泄露。既有新发布 3.4.0-mod 的实际包名为 **`com.agent2api.mobile.mod`**，并已换签。
两个包可同时存在，安装 `.mod` 不会替换或移除旧包；只卸载 `.mod` 也不会清除旧包。

1. 在旧 App 记录服务器地址、端口及显示名，准备重新登录面板。
2. 卸载旧包 `com.agent2api.mobile`。这会清除旧 App 的本地设置和登录态，但不卸载 Magisk 服务端模块。
3. 核对所装 APK 的实际包名、版本和发布证书，安装 `com.agent2api.mobile.mod`。
4. 启动新包后通过「自动发现」或手填恢复服务器配置，重新登录，并验证开关读写。
5. 系统包列表应保留新 `.mod`，旧 `com.agent2api.mobile` 应已消失。

```bash
adb shell pm list packages com.agent2api.mobile
adb uninstall com.agent2api.mobile
apksigner verify --verbose --print-certs Agent2API-3.4.1-mod.apk
aapt2 dump badging Agent2API-3.4.1-mod.apk
adb install -r Agent2API-3.4.1-mod.apk
adb shell pm list packages com.agent2api.mobile
```

以上安装命令对应**本轮本地 3.4.1 制品**。最终 APK SHA-256、版本、实际包名与证书已经记录在
[APK manifest](../upgrade-evidence/mobile/apk-manifest.json)。已有同签名 `.mod` 可正常升级保留数据；
本机 `.mod` 签名不同时才需要另行备份配置并卸载 `.mod`。

旧 localStorage 属于旧包沙箱，当前没有跨包自动迁移功能，不复制旧登录令牌。
需要重新建立服务器条目与登录态；设备验收记录不应仅以「安装成功」代替。

## 证书身份与处置状态

- 旧证书 SHA-256：`b18b0eb2078329a9963322e87f47669943655db857aa06c076dd868365c0bf15`。
- 既有3.4.0新证书 SHA-256：`d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`。
- 既有3.4.0 APK SHA-256：`4c7786e3c6c8e2532a43fb212afd9fcbf49d6ffb8d0186cbf844cee451618692`。
- 2026-11-04 独立复验时，旧签名 APK 仍在正式 `v3.1.4` Release 可下载；本轮未执行远端下架。
- Git 历史旧私钥对象仍存在，本轮未改写历史、未导出或生成私钥。
- 签名脚本黑名单与新包换签不会全局撤销旧证书；用户须主动卸载旧包。
- 已生成包含本轮修复的本地 3.4.1 APK；尚无本轮远端发布或设备迁移验收。发布与设备结果独立验收。

详细操作与每次发布检查见 [签名迁移](signing.md)，源码回归命令见 [APK 说明](README-mod.md)。
