# 手机端 3.4.1 升级与构建报告

## 结论

已在完整上游 v3.4.1 的独立 worktree 应用并重生成移动端补丁、刷新 7 个源码快照，保留 ToolsPage 路由与附件等新增功能。既有严格 boolean echo、epoch 写读屏障、串行写和 pending 隔离逻辑完整保留。182/182 动态前端用例、11/11 integration 和新增 17/17 来源完整性检查通过。真实 Node 完成原生 Web 构建，Gradle 完成 Android release；使用既有目标证书签名，未生成或替换签名 key。

最终本地 APK：

| 字段 | 实测值 |
|---|---|
| 文件 | [Agent2API-3.4.1-mod.apk](Agent2API-3.4.1-mod.apk) |
| bytes | 5,880,005 |
| SHA-256 | `94a208b7699acf1224cd2fc36913f58e7cffaf055b9651bbf26e7f3e52a01f9e` |
| applicationId | `com.agent2api.mobile.mod` |
| versionName / versionCode | `3.4.1` / `30401` |
| minSdk / targetSdk / compileSdk | `24` / `36` / `36` |
| APK 签名 | v2，1 signer，RSA 4096；`apksigner verify` exit 0 |
| 证书 SHA-256 | `d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f` |

未 commit/push、未操作远端 Release、未进行真机安装/迁移验收。

## 范围与来源

- 用户授权范围：upgrade 树的 apk-mod/**、必要 frontend 测试，以及本报告所在 upgrade-evidence/mobile。主代理负责 server/seed；本子任务未修改它们。
- 完整上游：同父目录 official-3.4.1，tag v3.4.1，commit `3ff4b8215d0d65c3451ca74923e90964ed7dbf59`。
- 独立构建 worktree：同父目录 mobile-build-3.4.1，detached HEAD 指向上述精确 commit。
- 原补丁 `git apply --3way` 干净应用，无冲突；重生成后仍为 6 个差异文件。第七快照 state/store.ts 是 3.4.1 上游原样内容，并不人为制造补丁差异。
- [source-manifest.json](source-manifest.json) 记录全部 7 个快照及补丁 SHA-256；补丁 SHA-256 `61e34897dc9d168319a238a6b522a96abd778cfe447006b69c7798bfcfc73317`。
- [源码校验脚本](../../apk-mod/verify-mobile-3.4.1.py) 校验精确 HEAD、7 份快照逐字节/哈希一致、补丁与 worktree staged delta 一致及可反向应用；ToolsPage/attachments/image-tools/read-tools/assistantTools 与上游逐文本文字一致，App 保留 ToolsPage import 与 tools route。

## 实际执行链

1. `git worktree add --detach ../mobile-build-3.4.1 3ff4b8215d0d65c3451ca74923e90964ed7dbf59`。
2. worktree 应用 apk-mod/a2a-mobile-mod.patch，随后运行 [refresh-mobile-3.4.1.py](../../apk-mod/refresh-mobile-3.4.1.py) 从 worktree 刷新补丁和快照。
3. mobile 与 sibling ui-kit 各自执行锁文件 `npm ci`，未修改 package/lockfile、未禁用 TypeScript 检查。
4. `npm run build:native` → `tsc --noEmit && vite build --mode apk`。
5. Capacitor `sync android`，原生插件 @capacitor/app 8.1.2、@capacitor/keyboard 8.0.6。
6. Gradle wrapper 8.14.3，AGP 8.13.0，`assembleRelease -PdevAppIdSuffix=.mod`，离线使用既有依赖缓存。
7. 构建脚本从外部环境读取 keystore 路径/口令文件路径，先验证公开证书指纹，再于 `androidComponents.finalizeDsl` 注入内存签名配置。临时 keystore.properties 仅含注释，finally 删除。
8. `apksigner verify --verbose --print-certs` 和 `aapt2 dump badging` 均 exit 0。元数据与目标值不符时脚本失败。
9. [APK 资产验证](apk-assets-verification.json)：178 份 assets/public Web 文件逐字节匹配本次 android-www，原生 app/keyboard 插件注册存在，resources.arsc 为 STORED。
10. 同一完整 helper 再跑一遍 npm ci → Web → cap sync → Gradle → 验签，全部 exit 0，最终 APK SHA-256 一致。

## 工具与环境

- 真实 Node：`E:/AI/tools/node/node.exe`，v24.22.2；npm 11。
- JDK：`E:/AI/tools/jdk21/jdk-21.0.12.1+1`。
- Android SDK：`E:/AI/tools/android-sdk`；platform 36 与 build-tools 36.0.0。
- TEMP/TMP：`E:/AI/tmp`；npm cache：`E:/AI/tmp/npm-cache`；Gradle cache：`E:/AI/tmp/gradle-home`。
- [build-mobile-3.4.1.py](../../apk-mod/build-mobile-3.4.1.py) 可执行完整构建或 `--skip-web`；默认使用现有离线 Gradle cache，无签名环境时输出明确命名的 unsigned APK。

## 证据 → 结论 → 路径

| Evidence | 原始观察/工件 | Finding |
|---|---|---|
| E-M01 | [source-manifest.json](source-manifest.json)、[source-verification.log](source-verification.log)：17/17 | F-M01 validated：3.4.1 精确来源，7 快照/补丁一致，ToolsPage 与附件等新功能保留 |
| E-M02 | [frontend-regression.log](frontend-regression.log)：182/182 + 11/11 | F-M02 validated：严格回显/读写屏障/epoch 等旧修复回归通过 |
| E-M03 | [build-native.log](build-native.log)、[cap-sync.log](cap-sync.log)、[gradle-release.log](gradle-release.log) | F-M03 validated：真实原生 Web 和 Android 构建成功，无类型检查旁路 |
| E-M04 | [apk-manifest.json](apk-manifest.json)、[apk-signature.log](apk-signature.log)、[apk-badging.log](apk-badging.log) | F-M04 validated：3.4.1-mod 制品身份和既有目标签名相符 |
| E-M05 | [apk-assets-verification.json](apk-assets-verification.json) | F-M05 validated：交付 APK 消费本次构建的全部 Web assets，所需原生插件存在 |

P-M01 构建路径：精确 tag → 独立 worktree → 原补丁 → 7 快照/重生补丁 → 完整依赖 → native Web → cap sync → Gradle release → 原证书签名 → APK 资产/元数据验证。全部结论置信度 high；覆盖边界是源码、构建与制品静态验证，而非真机行为。

## 失败尝试与修正

- 最初仅安装 mobile 依赖，TS2307 指向 sibling ui-kit 的 @base-ui/react / clsx / class-variance-authority / tailwind-merge 等缺失。修正为两个独立 package 均执行 npm ci，未用类型检查绕过或源码补丁掩盖依赖问题。
- [首次 Gradle 失败](gradle-first-invalid-java-home.log)：上游 org.gradle.java.home 写死不存在的 `C:/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot`。通过命令行 `-Dorg.gradle.java.home=E:/AI/tools/jdk21/jdk-21.0.12.1+1` 覆盖，不修改上游源文件。
- [第二次失败](gradle-second-signing-hook.log)：`It is too late to set storeFilePath`。由 projectsEvaluated 改用 androidComponents.finalizeDsl。
- [第三次失败](gradle-third-android-locations.log)：AndroidLocationsBuildService 初始化失败；移除额外 ANDROID_PREFS_ROOT（仍保留 ANDROID_USER_HOME）后构建成功。
- 完整 helper 重放的 Gradle `BUILD SUCCESSFUL in 42s`，204 actionable tasks：141 executed、63 up-to-date；最后新增精确 HEAD guard 后又跑 `--skip-web` 成功，当前保存日志为 `BUILD SUCCESSFUL in 13s`，204 tasks：1 executed、203 up-to-date，APK 散列不变。可写 metrics 首选目录提示未影响产物。
- 结束前扫描 33 份 apk-mod/证据文本工件，对实际口令内容的匹配数为 0；Git 跟踪清单无 jks/keystore/pass 文件，临时 signing properties 已删除。

## 复现与交接

```bash
# upgrade 树中；密钥和口令文件保持仓库外，由本地环境注入路径
export A2A_KEYSTORE=/outside/repository/a2a-release.jks
export A2A_KEYSTORE_PASS_FILE=/outside/repository/a2a-release.pass
export A2A_KEY_ALIAS=a2a
python apk-mod/build-mobile-3.4.1.py
python apk-mod/verify-mobile-3.4.1.py
python apk-mod/verify-apk-assets-3.4.1.py
NODE_BINARY=E:/AI/tools/node/node.exe python test/verify_frontend.py
```

补丁与快照刷新脚本用于独立 worktree 的 staged mobile 源码；不从 build 输出反向生成源码。当前 3.4.1 APK 与 3.4.0-mod 的包名/证书一致，可作为同签升级候选；旧 com.agent2api.mobile 的卸载迁移、远端旧 asset 状态与设备运行验证继续按主任务分别验收。所有本子任务后台 job 均已收集。
