# Agent2API 手机端 APK · 3.4.1-mod（配套 Magisk 模块）

把官方 **v3.4.1 源码**（`desktop-tauri/mobile`，Capacitor 8 + React 19）直接构建成
**能自己找到本机模块网关、并且功能开关与桌面面板双向同步**的 APK。

- 既有发布产物：`Agent2API-3.4.0-mod.apk`（5.50 MB / 已签名 / `com.agent2api.mobile.mod`）；它尚未包含本轮写屏障与严格回显修复。
- 基线：上游 tag `v3.4.1`（commit `3ff4b8215d0d65c3451ca74923e90964ed7dbf59`）的完整源码，在同父目录 `mobile-build-3.4.1` 独立 worktree 构建。
- 源码补丁：[a2a-mobile-mod.patch](a2a-mobile-mod.patch)（6 个差异文件）；仓库保留 7 个 3.4.1 源码快照，未覆盖上游 ToolsPage 工具服务路由、会话附件、图片/读取工具等新增实现。
- 本轮状态：182/182 动态回归与 11/11 integration 通过，`npm run build:native`、Capacitor 同步及 Android `assembleRelease` 实际成功。
- 本轮产物：[Agent2API-3.4.1-mod.apk（Release 下载）](https://github.com/84593320z/agent2api-magisk/releases/tag/apk-v3.4.1-mod)，5,880,005 bytes，`com.agent2api.mobile.mod` / versionName `3.4.1` / versionCode `30401`；复用既有 `d0ca6713…b16f` 证书，APK v2 签名验证通过。最终散列见 [APK manifest](../docs/upgrade-3.4.1/evidence/apk-manifest.json)，构建证据见 [升级验收报告](../docs/upgrade-3.4.1/report.md)。
- 已验收本地制品按本仓 Release 发布；真机安装验收未执行。下文 3.4.0 构建数据及升级验收报告中的“未发布”描述均为发布前历史记录，当前发布入口以上述 Release 为准。
- 与 3.1.2 版的最大区别：**这次从源码完整构建（含原生层），不再拿官方 APK 替换
  `assets/public` 重打包** —— `@capacitor/app` 真正进了包，硬件返回键问题随之消失（见 3.3）。

---

## 1. 改了什么

### 1.1 自动发现本机网关

**原来的问题**：APK 的界面打在包里，页面 origin 是 `https://localhost`，与网关必然跨源，
所以必须在「服务器」页手填 `IP:端口`。可当网关就跑在同一台手机的 Magisk 模块里时，
用户手上根本没有「IP」这个概念 —— 手填 `127.0.0.1:3065` 等于把内部实现甩给用户。

**现在的行为**：

- **首次启动自动发现**：一台服务器都没配时，在环回地址上并发探 `3060~3080`（默认 3065 优先），
  1.2 秒内出结果。探到就自动建条目、切过去、直接拉会话。
- **手动兜底**：「服务器」页右上角新增「自动发现」按钮，随时重扫；列表为空时还有一张引导卡。
- **只扫环回**：不扫局域网网段（254 次探测又慢又像端口扫描）。连别的机器仍然手填。
- **识别判据是两段，任一段命中即认**（不是「HTTP 200」就算）：

  | 段 | 探测 | 判据 | 适用形态 |
  |---|---|---|---|
  | 1 | `GET /health` | 带 `transport` / `authRequired` / `upstreamConfigured` / `defaultModel` / `chatApiUrl` / `authApiBase` 任一 | 桌面端形态（完整摘要） |
  | 2 | `GET /api/panel/status` | 回 `{success:true,data:{registered:boolean}}` 信封（或裸 `{registered:boolean}`） | 手机模块的 headless 形态 |

  第 2 段是 3.1.2 版在真机上踩过的坑：模块跑的 headless 服务会把面板闸门打开
  （`access::set_panel_gate(true)`，只有 `AGENT2API_ALLOW_NO_KEY=1` 才清零），这时
  `/health` **只回 `{"status":"ok"}`**（15 字节，除非显式开了「允许无 Key」），完整摘要不外泄 —— 只认第 1 段的实现
  在手机上永远探不到自家网关。`/api/panel/status` 挂在 public 路由上（登录页要先问
  「注册过没有」），响应形状是本家独有，刚好当第二指纹；两段都不要求管理员已注册。

### 1.2 功能开关与面板双向同步

**原来的问题**：手机端设置页只放了「外观 / 语言 / 凭证 / 关于」，网关的行为开关
（脱敏、兼容、调试、跨域、人机校验、models.dev、路由自愈三项）**只有桌面面板能改**。

**现在**：设置页新增「网关功能开关」，两组共 **9 个开关**，与桌面面板
「设置 → 网关」**同一批端点、同一批字段**：

| 分组 | 开关 | 端点 | 字段 |
|---|---|---|---|
| 网关行为 | 出站指纹脱敏 | `GET/PUT /api/sanitize` | `sanitizeBlacklistFingerprints` |
| 网关行为 | 开发者角色兼容 | `GET/PUT /api/developer-role-compat` | `developerRoleCompat` |
| 网关行为 | 网关跨域访问 | `GET/PUT /api/cors` | `corsEnabled` |
| 网关行为 | 调试模式 | `GET/PUT /api/debug` | `debugMode` |
| 网关行为 | 登录人机校验 | `GET/PUT /api/captcha` | 写入 `captchaEnabled`；读取按当前端取 `captchaDesktop` / `captchaWeb` |
| 网关行为 | models.dev 元数据 | `GET/PUT /api/models/metadata` | `modelsDevEnabled` |
| 路由自愈 | 失败退避 | `GET/PUT /api/routing` | `routingFailoverBackoff` |
| 路由自愈 | 限流垫底 | `GET/PUT /api/routing` | `routingSink` |
| 路由自愈 | 熔断 | `GET/PUT /api/routing` | `routingBreakerEnabled` |

**同步怎么成立的**（没有推送通道，靠同一份服务端状态 + 两端回读）：

- 面板改了 → 手机端设置页可见时**每 5 秒回读**一次，从后台切回前台立刻读；
- 手机改了 → `PUT` 目标字段必须是 boolean 且严格等于请求值，才提交确认；空响应、类型错误及反向回显均作为保存失败；
- PUT 同一份值是幂等操作；多端竞争仍以服务端最后确认状态与后续回读为准；
- 保存失败删除该键，显示未知/禁用并在设置页显示错误，不伪造回滚值或成功提示。

本轮源码修复保留并强化三条写读规则（[GatewaySwitches.tsx](src/components/GatewaySwitches.tsx)）：

1. **读不到 = 未知 = 禁用**：请求失败时开关置灰不可点，不给「看起来是关的」假状态；
2. **写串行**：同一时刻只发一个 PUT，后面的排队，避免两个开关互相覆盖；
3. **读不能跨写屏障**：写入队与结算（包括失败）均推进代次，跨越屏障的旧 GET 整份丢弃；
   `pending` 隔离不同键的在途意图，延迟执行的 React updater 也复查代次。写后新 GET 仍可正常更新。
   写失败则删键回到「未知」并提示「开关保存失败，请检查网关是否可达」。

轮询在 `document.visibilityState === 'hidden'` 时跳过。

---

## 2. 安装

先在旧 App 记录服务器地址/端口与显示名，准备重新登录面板。旧包 localStorage 不会跨包自动迁移。
旧实际包名是 `com.agent2api.mobile`，新包是 `com.agent2api.mobile.mod`；两者可共存，安装新包不会消除旧包信任。

```bash
# 1) 已安装旧包的用户：卸载实际旧包，而不是只卸载 .mod
adb uninstall com.agent2api.mobile
# 2) 核对证书指纹（见第5节）与实际新包名，再安装既有发布包
apksigner verify --print-certs Agent2API-3.4.0-mod.apk
adb install -r Agent2API-3.4.0-mod.apk
# 3) 应只保留 package:com.agent2api.mobile.mod，没有 package:com.agent2api.mobile
adb shell pm list packages com.agent2api.mobile
```

已有同签名 `.mod` 包可升级保留数据；只有已有 `.mod` 的证书与目标不同才另行卸载 `.mod`。
卸载清除 App 本地配置/登录态，不操作 Magisk 服务端数据；新包中自动发现/手填恢复后重新登录。
完整设备验收与外部处置状态见 [签名迁移](signing.md)；发布正文模板见 [Release 迁移说明](release-migration.md)。

首次启动会自动连上 `127.0.0.1:3065`；连不上（模块没启动 / 端口改过）就落到
「服务器」页，点「自动发现」或手填。

> 装完在「设置 → 关于」看到 **`3.4.0`** 就是这一版（这次连清单里的 versionName
> 都是上游真值，不再是 3.1.0 冒充）。

---

## 3. 验证记录

### 3.1 既有发布的构建记录（非本轮重构建）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 类型检查 + 打包 | `tsc --noEmit && vite build --mode apk` | 通过（752 modules，`mobile.js` 955.96 kB / gzip 306.58 kB） |
| 原生同步 | `npx cap sync android` | 2 个插件：`@capacitor/app@8.1.2`、`@capacitor/keyboard@8.0.6` |
| 原生构建 | `gradlew assembleRelease -PdevAppIdSuffix=.mod` | `BUILD SUCCESSFUL`（JDK 21 / AGP 8.13 / Gradle 8.14.3 / compileSdk 36） |
| 签名 | `apksigner verify --print-certs` | 通过；证书 SHA-256 `d0ca6713…b16f`（新钥匙，非泄露的 `b18b0eb2…bf15`） |
| 包信息 | `aapt2 dump badging` | `com.agent2api.mobile.mod` / `versionName 3.4.0` / `versionCode 30400` / minSdk 24 / targetSdk 36 |
| 产物内容 | `unzip -p … assets/public/mobile.js` | `api/panel/status`、`captchaDesktop`、`routingBreakerEnabled` 等关键词均在；`assets/capacitor.plugins.json` 含 `@capacitor/app`、`@capacitor/keyboard` |

本轮源码回归使用实际拆分组件与 API，控制 HTTP 响应顺序并模拟即时/延迟 React updater，
覆盖未知禁用、跨 PUT 旧 GET、写失败、全局串行、pending 隔离和严格 boolean 回显；同时校验三份新增文件的 patch 快照一致。
测试要求 Python 3 与 Node >=22.13，无 npm 依赖：

```bash
python test/verify_frontend.py
# 可显式指定真实 Node 运行时
NODE_BINARY=/path/to/node python test/verify_frontend.py
# 独立动态套件，可输出结构化证据
node test/verify_frontend_runtime.mjs --report frontend-runtime-results.json
```

以上命令在本仓库根目录执行；它们不是 TypeScript 全工程检查、APK 构建或真机 UI 验收。

### 3.2 真机（3.1.2 版记录，3.4.0 待复验）

3.1.2 版真机验证过的项目（KernelSU + ColorOS / Android 15，1440×3168）：

| 验证项 | 方法 | 结果 |
|---|---|---|
| 自动发现 | 全新安装后首次启动 | 自动建条目「本机网关 127.0.0.1:3065」并连上，首页拉出 15/17 账号 |
| 开关渲染 | 设置页 | 9 个开关全部显示，状态与网关实际配置一致 |
| **面板 → APK** | 面板令牌 `PUT /api/debug {"debugMode":true}` | 7 秒后 App 里「调试模式」自动变绿（轮询生效） |
| **APK → 面板** | 在 App 里拨动「调试模式」 | `GET /api/debug` 立即返回 `debugMode:false` |
| 应用内返回 | 二级页左上角 `‹` | 正常回到上一级（设置 → 更多） |
| 稳定性 | 反复进出各页面 | 无崩溃（logcat 无 FATAL EXCEPTION） |

**3.4.0 尚未上真机**：本仓库的验证只做到「构建 + 签名 + 包内容抽检」。
自动发现的新判据（`/api/panel/status` 段）与硬件返回键需要在装了本模块的手机上
实测一次确认。

---

## 3.3 硬件返回键（3.1.2 的问题，3.4.0 已从源码层解决）

**3.1.2 的现象**：任意二级页按系统返回键/返回手势，直接退回桌面。

**3.1.2 的根因**：那个包是「官方 APK + 替换 `assets/public`」重打包的，
`assets/capacitor.plugins.json` 是 `[]` —— `@capacitor/app` 没进包，原生层也没有
`OnBackPressedCallback`，系统只能 `finish()`。当时试过的三种原生补丁都因为拿不到
WebView 实例而回退。

**3.4.0 为什么解决**：从源码完整构建，`@capacitor/app@8.1.2` 已注册
（`assets/capacitor.plugins.json` 可见），`App.tsx` 里上游自带的 `backButton`
监听会把事件转给 JS：能回退就 `history.back()`，到根页面才 `exitApp()`。
仍需真机点一次确认（见 3.2）。

---

## 4. 已知限制

- **迁移必须卸载实际旧包 `com.agent2api.mobile`**：新 `.mod` 与旧包是不同 applicationId，不是同包跨签更新；同签名 `.mod` 后续升级无需卸载。
- **不做局域网扫描**：只探环回。连别的机器请手填地址。
- **不暴露「局域网访问 / 开放面板」两个开关**：它们在桌面端要写应用配置并**重启网关**，
  手机上做这件事需要改 `env.sh`（`AGENT2API_HOST`）并 `ctl restart`，属于模块侧的活，
  放进 App 里会做出「拨了没反应」的假开关。
- **新增文案只有中文**：i18n 词典没有扩充，非中文语种下这一块回落中文原文。
- **上游更新会覆盖**：`ctl update` 只换服务端二进制与 `ui/`，不动 APK；
  但下次装官方新 APK 会变回原样，需要重新打这个补丁。

---

## 5. 自己重建

前置：JDK 21、Android SDK（`platforms;android-36`、`build-tools;36.0.0`、`build-tools;35.0.0`）、
Node 20+。

```bash
# 1) 源码 + 补丁
git clone https://github.com/aimod-cc/Agent2API.git && cd Agent2API
git checkout v3.4.1
git apply /path/to/a2a-mobile-mod.patch

# 2) 两个独立 package 都须安装锁定依赖
cd desktop-tauri/ui-kit && npm ci
cd ../mobile && npm ci

# 3) Web 产物 + 同步原生工程
mkdir -p android-www
npm run build:native
npx cap sync android

# 4) 原生构建
export JAVA_HOME=/path/to/jdk21
export ANDROID_HOME=/path/to/android-sdk
export TEMP=/tmp TMP=/tmp          # esbuild 需要可写临时目录
cd android
#   android/local.properties      -> sdk.dir=<SDK 路径>
#   android/keystore.properties   -> storeFile/storePassword/keyAlias/keyPassword
./gradlew assembleRelease -PdevAppIdSuffix=.mod
# 产物：android/app/build/outputs/apk/release/app-release.apk
```

本机完整可重放脚本：[build-mobile-3.4.1.py](build-mobile-3.4.1.py)。它默认使用真实 Node/JDK21/现有 SDK，先执行 mobile 与 ui-kit 的 `npm ci`，再执行原生 Web 构建、Capacitor 同步、离线 Gradle release 构建与 APK 元数据/签名验证。已有 Web 产物时可用 `--skip-web`。

```bash
# 已在完整 v3.4.1 独立 worktree 应用补丁后，从 upgrade 树运行
# 签名路径由部署环境注入，口令文件仅读入内存；脚本从不新建签名 key
export A2A_KEYSTORE=/outside/repository/a2a-release.jks
export A2A_KEYSTORE_PASS_FILE=/outside/repository/a2a-release.pass
export A2A_KEY_ALIAS=a2a
python apk-mod/build-mobile-3.4.1.py
python apk-mod/verify-mobile-3.4.1.py
NODE_BINARY=E:/AI/tools/node/node.exe python test/verify_frontend.py
```

脚本固定校验当前发布证书 `d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`；未设置签名路径时输出明确命名的 `-unsigned.apk`。Gradle signing 通过 `androidComponents.finalizeDsl` 注入内存，临时的 `keystore.properties` 仅有注释并在 `finally` 中清理。证据目录只保存公开证书摘要与构建结果。

两处需要适配的上游默认值：

1. `android/gradle.properties` 里写死的 `org.gradle.java.home` 指着作者机器上的
   `C:/Program Files/Eclipse Adoptium/jdk-21.0.11.10-hotspot`，本机没有就会直接报
   `Java home supplied is invalid` —— 删掉这行（靠 `JAVA_HOME`）或改成你的路径；
2. `android/local.properties` 的 `sdk.dir` 要指到你自己的 Android SDK。

`repack.py` 仍保留为「没有 Android SDK 时的备用方案」（官方 APK + 替换
`assets/public`，代价是 versionName 跟着官方包走、且原生层插件缺失）：

```bash
python repack.py --apk Agent2API-<ver>.apk --web android-www --out ...-mod-unsigned.apk
zipalign -p -f 4 ...-mod-unsigned.apk ...-mod-aligned.apk
```

它有一条不能动的规则：**`resources.arsc` 必须保持 STORED**，否则 Android 11+ 装不上。

### 签名

**不要把签名私钥提交进仓库。** 本仓库早期版本曾把 `a2a-mod.jks` 连同口令一起
提交（可 `git show <old-commit>:apk-mod/a2a-mod.jks` 取回）——那等于把发布私钥
公开：拿到仓库的人可以签出**同包名、同证书**的 APK，Android 会把它当成正常
升级接受证书校验（仍需安装动作），所以这把钥匙只能按「已泄露」处理：

- 不能再用它签任何新版本（`apk-mod/sign-tool.sh` 会直接拒绝这个证书指纹，
  指纹常量在同一文件顶部）；
- 已经用旧钥匙装上的手机**不会自动变安全**——签名校验只发生在安装时，
  攻击者签的包同样能通过；用户需要按 `apk-mod/signing.md` 主动换成新签名版本。

本版（3.4.1-mod）复用 3.4.0-mod 的既有新钥匙签名，证书 SHA-256
`d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`。

新钥匙用脚本生成（默认拒绝写进仓库目录，口令随机并单独落 600 文件）：

```bash
sh apk-mod/sign-tool.sh new --out ~/.a2a-signing
sh apk-mod/sign-tool.sh fingerprint --keystore ~/.a2a-signing/a2a-release.jks
```

签名时用环境变量传路径与口令，别写进脚本或命令历史：

```bash
export A2A_KEYSTORE=~/.a2a-signing/a2a-release.jks
export A2A_KEY_ALIAS=a2a
export A2A_KEYSTORE_PASS=$(cat ~/.a2a-signing/a2a-release.pass)
apksigner sign --ks "$A2A_KEYSTORE" --ks-key-alias "$A2A_KEY_ALIAS" \
  --ks-pass env:A2A_KEYSTORE_PASS \
  --out ...-mod.apk ...-aligned.apk
```

同包名跨签名无法直接覆盖；本次既有3.4.0发布还改了包名，因此安装 `.mod` 不会替换旧的
`com.agent2api.mobile`。必须明确卸载旧包，再恢复配置并登录；见 [签名迁移](signing.md)。
2026-11-04 复验时正式旧签名 asset 仍在，历史私钥对象仍存在；本地源码修复没有删除远端 asset、
改写发布正文或抹去 Git 历史。后续发版前需分别验收旧资产下架、完整构建和用户迁移。

`*.jks` / `*.keystore` / `*.pass` 已被根 `.gitignore` 排除；任何情况下都不要
为了「方便别人复现」把私钥或口令放进 git（包括示例、截图、CI 日志）。
