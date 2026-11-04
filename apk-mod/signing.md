# 发布签名与旧包迁移

旧包 `com.agent2api.mobile` 使用的 APK 签名私钥曾进入 Git 历史，按已泄露处理。
已发布的 3.4.0-mod 使用新证书及新包名 `com.agent2api.mobile.mod`；**安装新包不会替换或卸载旧包**。
本地源码修复、签名轮换、远端旧资产下架、用户设备迁移是四件独立的事。

## 1. 已核实的制品身份

2026-11-04 独立复验记录：

| 项目 | 旧制品 | 已发布的新制品 |
|---|---|---|
| 发布标签 | `v3.1.4` | `apk-v3.4.0-mod` |
| APK 文件名 | `Agent2API-3.1.2-mod.apk` | `Agent2API-3.4.0-mod.apk` |
| 实际 applicationId | `com.agent2api.mobile` | `com.agent2api.mobile.mod` |
| versionName / versionCode | `3.1.0` / `30100` | `3.4.0` / `30400` |
| 证书 SHA-256 | `b18b0eb2078329a9963322e87f47669943655db857aa06c076dd868365c0bf15` | `d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f` |
| APK SHA-256 | `e5b49db094fbbe2ba2cda645043db28dcda83c73c9098d1f3062a8eedd3fefd2` | `4c7786e3c6c8e2532a43fb212afd9fcbf49d6ffb8d0186cbf844cee451618692` |

旧私钥文件的历史 SHA-256 为 `25cb9dbd9ddae971347f1499bee97bf6bd8f2c64380d973179dac4cb774a472d`；
历史对象 `23b881d:apk-mod/a2a-mod.jks` 仍存在。当前树删除并忽略私钥不等于删除历史副本。
本次修复未生成、导出或修改任何私钥。

Android 对同包升级校验证书，但上表是**两个包名**，可以同时安装。旧私钥持有者仍能为旧包签署
系统接受的同证书更新。换新签名、脚本黑名单均不是 Android 对旧证书的全局撤销机制，设备上仍须卸载旧包。

## 2. 用户迁移：先记录配置，再卸载实际旧包

1. 在旧 App 的「服务器」页记录服务器地址、端口和显示名，确认仍有面板账号的登录方式。
   不要将面板登录令牌放进截图、工单或公开备份。旧 App 的 WebView localStorage 属于旧包沙箱，
   新包不会自动继承；本项目未实现跨包 localStorage 导出/导入。
2. 卸载实际旧包 `com.agent2api.mobile`。卸载会清除该包的服务器配置与面板登录态。
   Magisk 服务端的数据位于独立模块目录，本步骤只操作 Android App，不卸载模块、不清理服务端数据。
3. 验证新 APK 的实际包名与证书；再安装新包 `com.agent2api.mobile.mod`。
4. 首次启动点「自动发现」或重新填写记录的地址，重新登录面板。逐项核对服务器和网关开关。

```bash
# adb37 为本机已配置的 Android platform-tools 37 别名；其他环境可用对应 adb。
adb37 shell pm list packages com.agent2api.mobile
# 如果列出 package:com.agent2api.mobile，卸载它（不能只卸载 .mod）。
adb37 uninstall com.agent2api.mobile

apksigner verify --verbose --print-certs Agent2API-3.4.1-mod.apk
aapt2 dump badging Agent2API-3.4.1-mod.apk
# 证书/包名与上表的新发布身份一致；本轮3.4.1制品包含源码修复。
adb37 install -r Agent2API-3.4.1-mod.apk

# 列表应只保留 package:com.agent2api.mobile.mod，没有 package:com.agent2api.mobile。
adb37 shell pm list packages com.agent2api.mobile
```

手机上操作时，在系统设置的应用详情核对包名 `com.agent2api.mobile` 并卸载，再安装新包。
已经安装且证书与新发布一致的 `.mod` 包可进行同签名升级，保留其数据；只有本机已有 `.mod`
包的签名与目标签名不同才需要先记录配置，再单独卸载 `com.agent2api.mobile.mod`。
卸载 `.mod` 不能代替卸载旧的 `com.agent2api.mobile`。

迁移验收应保留设备记录：旧包卸载结果、新包版本/证书、自动发现/手填恢复、重新登录、开关读写。
目前没有本轮真机迁移验收记录，不能将文档更新记为用户设备已经迁移。

## 3. 发布与外部处置状态

| 项目 | 当前状态 | 后续验收 |
|---|---|---|
| 当前源码树的私钥材料 | 已移除，根 `.gitignore` 忽略 `*.jks` / `*.keystore` / `*.pass` | 每次发布检查跟踪清单与日志 |
| 3.4.0-mod 既有发布签名 | 新证书已实测，指纹见上表 | 每个后续制品重新验签 |
| 旧正式 Release asset | 2026-11-04 复验仍能下载；本次没有执行远端删除 | 维护者撤下旧签名 APK，并独立复核发布页及分发镜像 |
| 历史私钥对象 | 仍可恢复；本次没有改写 Git 历史 | 如另行清历史，记录仓库协调与旧副本仍存在的事实 |
| 已安装用户的旧 signer 信任 | 本地代码无法自动消除 | 按第2节逐台卸载旧包并验收 |
| 本轮写屏障/回显修复的 APK | 已从 v3.4.1 完整工程生成本地 3.4.1-mod APK，沿用 d0ca6713…b16f 证书，v2 验签通过 | [制品身份与散列](../upgrade-evidence/mobile/apk-manifest.json)；远端发布、设备验收分别记录 |

可复制到后续发布页的迁移说明见 [Release 迁移说明](release-migration.md)。
既有远端 Release 正文不随本地 Markdown 修改而改变。

## 4. 后续签名与发布检查

后续版本复用已经轮换的新发布身份，由维护者在仓库外保管密钥。不要因修复前端而重复轮换证书。
用既有密钥验指纹、签名，不在本次修复中创建密钥：

```bash
sh apk-mod/sign-tool.sh fingerprint --keystore "$A2A_KEYSTORE" --alias "$A2A_KEY_ALIAS"
apksigner sign --ks "$A2A_KEYSTORE" --ks-key-alias "$A2A_KEY_ALIAS" \
  --ks-pass env:A2A_KEYSTORE_PASS --out Agent2API-mod.apk Agent2API-mod-aligned.apk
apksigner verify --verbose --print-certs Agent2API-mod.apk
```

- [ ] 签名证书匹配维护者的发布记录，且不同于上表旧泄露证书。
- [ ] `git ls-files '*.jks' '*.keystore' '*.pass'` 无输出，签名口令不进入日志。
- [ ] 对最终 APK 记录 SHA-256、实际 applicationId、版本、证书指纹。
- [ ] 构建使用完整上游工程；快照与 patch 保持一致，动态前端回归通过。
- [ ] 发布页明确旧包 `com.agent2api.mobile` 卸载及配置重建，区别 `.mod` 同签升级。
- [ ] 外部旧资产下架与设备迁移分别记录结果，不能仅以签名脚本检查代替。

## 5. 历史处置的含义

改写历史可以减少新克隆取得私钥的路径，但镜像、fork、旧克隆及缓存仍可能持有副本，
不会使旧私钥重新成为秘密。本轮保留历史事实与引用，不执行历史重写或远端发布操作。
已完成的是源码修复、迁移说明统一与完整 v3.4.1 工程的本地签名 APK 构建；旧资产下架、远端发布、设备迁移仍按各自证据验收。
