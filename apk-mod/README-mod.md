# Agent2API 手机端 APK · 3.4.0-mod（配套 Magisk 模块）

把官方 **v3.4.0 源码**（`desktop-tauri/mobile`，Capacitor 8 + React 19）直接构建成
**能自己找到本机模块网关、并且功能开关与桌面面板双向同步**的 APK。

- 产物：`Agent2API-3.4.0-mod.apk`（5.50 MB / 已签名 / `com.agent2api.mobile.mod`）
- 基线：上游 tag `v3.4.0`（commit `31bc7bd`）的 `desktop-tauri/mobile` 源码
- 源码补丁：`a2a-mobile-mod.patch`（6 文件，对 `desktop-tauri/mobile/src` 的完整 diff）
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
- 手机改了 → `PUT` 成功，响应体就是新状态，界面直接用它渲染（不是只做本地乐观更新）；
- 写操作幂等（PUT 同一份值），两边同时拨不会互相打架；
- 拨动失败会回滚 + toast，不静默吞掉。

3.4.0 又补了三条写读规则（`GatewaySwitches.tsx` 里有注释）：

1. **读不到 = 未知 = 禁用**：请求失败时开关置灰不可点，不给「看起来是关的」假状态；
2. **写串行**：同一时刻只发一个 PUT，后面的排队，避免两个开关互相覆盖；
3. **在途值不被回读覆盖**：乐观更新后把值记进 `pending`，5 秒轮询拿到的旧值不会把
   用户刚点的状态弹回去；写失败则删键回到「未知」并提示「开关保存失败，请检查网关是否可达」。

轮询在 `document.visibilityState === 'hidden'` 时跳过。

---

## 2. 安装

```bash
# 1) 与官方包 applicationId 不同（.mod 后缀），但签名也不同，干净装最省事
adb uninstall com.agent2api.mobile.mod
# 2) 装改造版
adb install -r Agent2API-3.4.0-mod.apk
```

首次启动会自动连上 `127.0.0.1:3065`；连不上（模块没启动 / 端口改过）就落到
「服务器」页，点「自动发现」或手填。

> 装完在「设置 → 关于」看到 **`3.4.0`** 就是这一版（这次连清单里的 versionName
> 都是上游真值，不再是 3.1.0 冒充）。

---

## 3. 验证记录

### 3.1 构建期（3.4.0）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 类型检查 + 打包 | `tsc --noEmit && vite build --mode apk` | 通过（752 modules，`mobile.js` 955.96 kB / gzip 306.58 kB） |
| 原生同步 | `npx cap sync android` | 2 个插件：`@capacitor/app@8.1.2`、`@capacitor/keyboard@8.0.6` |
| 原生构建 | `gradlew assembleRelease -PdevAppIdSuffix=.mod` | `BUILD SUCCESSFUL`（JDK 21 / AGP 8.13 / Gradle 8.14.3 / compileSdk 36） |
| 签名 | `apksigner verify --print-certs` | 通过；证书 SHA-256 `d0ca6713…b16f`（新钥匙，非泄露的 `b18b0eb2…bf15`） |
| 包信息 | `aapt2 dump badging` | `com.agent2api.mobile.mod` / `versionName 3.4.0` / `versionCode 30400` / minSdk 24 / targetSdk 36 |
| 产物内容 | `unzip -p … assets/public/mobile.js` | `api/panel/status`、`captchaDesktop`、`routingBreakerEnabled` 等关键词均在；`assets/capacitor.plugins.json` 含 `@capacitor/app`、`@capacitor/keyboard` |

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

- **必须卸载旧包**再装：签名是新的（见第 5 节「签名」），且 applicationId 带 `.mod`。
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
git checkout v3.4.0
git apply /path/to/a2a-mobile-mod.patch

# 2) 依赖（ui-kit 的运行期依赖要一次装全，分次 --no-save 会被 npm 相互裁掉）
cd desktop-tauri/mobile
npm ci
npm install --no-save class-variance-authority clsx tailwind-merge tw-animate-css shadcn

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

两处必须改的上游默认值：

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
升级**静默覆盖**已经装了旧包的手机。所以这把钥匙只能按「已泄露」处理：

- 不能再用它签任何新版本（`apk-mod/sign-tool.sh` 会直接拒绝这个证书指纹，
  指纹常量在同一文件顶部）；
- 已经用旧钥匙装上的手机**不会自动变安全**——签名校验只发生在安装时，
  攻击者签的包同样能通过；用户需要按 `apk-mod/signing.md` 主动换成新签名版本。

本版（3.4.0-mod）已用新钥匙签名，证书 SHA-256
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

跨签名的包**不能覆盖安装**：换钥匙后老用户必须卸载重装，具体迁移步骤和发版顺序
见 `apk-mod/signing.md`。

`*.jks` / `*.keystore` / `*.pass` 已被根 `.gitignore` 排除；任何情况下都不要
为了「方便别人复现」把私钥或口令放进 git（包括示例、截图、CI 日志）。
