# Agent2API 手机端 APK · 3.1.2-mod（配套 Magisk 模块）

把官方 `Agent2API-3.1.0.apk`（Capacitor 壳 + 打包进包里的手机面板）改造成
**能自己找到本机模块网关、并且功能开关与桌面面板双向同步**的版本。

- 产物：`Agent2API-3.1.2-mod.apk`（4.63 MB / 已签名）
- 基线：官方 v3.1.0 的 APK（`assets/public/mobile.js` 由本仓库源码重新构建）
- 源码补丁：`a2a-mobile-mod.patch`（对 `desktop-tauri/mobile` 的完整 diff）
- 构建产物：`android-www/`（可直接替换进任意 3.1.0 APK）

---

## 1. 改了什么

### 1.1 自动发现本机网关

**原来的问题**：APK 的界面打在包里，页面 origin 是 `https://localhost`，与网关必然跨源，
所以必须在「服务器」页手填 `IP:端口`。可当网关就跑在同一台手机的 Magisk 模块里时，
用户手上根本没有「IP」这个概念 —— 手填 `127.0.0.1:3065` 等于把内部实现甩给用户。

**现在的行为**：

- **首次启动自动发现**：一台服务器都没配时，在环回地址上并发探 `3060~3080`（默认 3065 优先），
  1.2 秒内出结果。探到就自动建条目、切过去、直接拉会话。
- **手动兜底**：「服务器」页右上角新增「自动发现」按钮，随时重扫。
- **识别判据**不是「HTTP 200」，而是 `/health` 响应体里带本家特征字段
  （`authRequired` / `chatApiUrl` / `upstreamConfigured` / `defaultModel` / `authApiBase`）——
  3065 是常用端口，别的服务也可能在那儿返回 200。
- **只扫环回**：不扫局域网网段（254 次探测又慢又像端口扫描）。连别的机器仍然手填。

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
| 网关行为 | 登录人机校验 | `GET/PUT /api/captcha` | `captchaEnabled` |
| 网关行为 | models.dev 元数据 | `GET/PUT /api/models/metadata` | `modelsDevEnabled` |
| 路由自愈 | 失败退避 | `GET/PUT /api/routing` | `routingFailoverBackoff` |
| 路由自愈 | 限流垫底 | `GET/PUT /api/routing` | `routingSink` |
| 路由自愈 | 熔断 | `GET/PUT /api/routing` | `routingBreakerEnabled` |

**同步怎么成立的**（没有推送通道，靠同一份服务端状态 + 两端回读）：

- 面板改了 → 手机端设置页可见时**每 5 秒回读**一次，从后台切回前台立刻读；
- 手机改了 → `PUT` 成功，响应体就是新状态，界面直接用它渲染（不是只做本地乐观更新）；
- 写操作幂等（PUT 同一份值），两边同时拨不会互相打架；
- 拨动失败会回滚 + toast，不静默吞掉。

---

## 2. 安装

```bash
# 1) 官方版签名不同，必须先卸载（否则 INSTALL_FAILED_UPDATE_INCOMPATIBLE）
adb uninstall com.agent2api.mobile
# 2) 装改造版
adb install -r Agent2API-3.1.2-mod.apk
```

首次启动会自动连上 `127.0.0.1:3065`；连不上（模块没启动 / 端口改过）就落到
「服务器」页，点「自动发现」或手填。

> 装完在「设置 → 关于」看到 **`3.1.2-mod · 本机网关自动发现 + 功能开关双向同步`**
> 就是这一版（APK 清单里的 versionName 仍是上游的 3.1.0，因为改二进制清单风险大于收益）。

---

## 3. 验证记录

### 3.1 真机（KernelSU + ColorOS / Android 15，1440×3168）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 自动发现 | 全新安装后首次启动 | 自动建条目「本机网关 127.0.0.1:3065」并连上，首页拉出 15/17 账号 |
| 开关渲染 | 设置页 | 9 个开关全部显示，状态与网关实际配置一致 |
| **面板 → APK** | 用面板令牌 `PUT /api/debug {"debugMode":true}` | 7 秒后 App 里「调试模式」自动变绿（轮询生效） |
| **APK → 面板** | 在 App 里拨动「调试模式」 | `GET /api/debug` 立即返回 `debugMode:false` |
| 应用内返回 | 二级页左上角 `‹` | 正常回到上一级（设置 → 更多） |
| 稳定性 | 反复进出各页面 | 无崩溃（logcat 无 FATAL EXCEPTION） |

> 真机验证推翻了一个浏览器环境下的结论：手机端网关的 `/health` 只返回
> `{"status":"ok"}`（15 字节），而桌面版返回一大串字段。最初的识别判据只认后者，
> 导致「自家网关被判成不是」。现在改成 `/health` + `/api/panel/status`
> （必须回 `{registered:boolean}`）两段式判据。

### 3.2 浏览器冒烟（构建期）

| 验证项 | 方法 | 结果 |
|---|---|---|
| 构建 | `vite build --mode apk`（555 modules） | 通过 |
| 开关写入 | mock `/api/*` + 点击 | `PUT /api/sanitize {"sanitizeBlacklistFingerprints":false}` ✅ |
| 端点真实性 | 对真网关逐个 GET | 7 个端点全部 `401`（存在且要鉴权），无 404 |

---

## 3.3 已知问题：硬件返回键会直接退出应用

**现象**：在任意二级页按系统返回键/返回手势，应用直接退回桌面，而不是回到上一级。

**根因（已定位到源码级）**：

1. 这个 APK 用 Capacitor 8，而 `@capacitor/android` 里**一处 `onBackPressed` 都没有** ——
   `BridgeActivity` 完全不处理返回键，`MainActivity` 又是空实现，系统只能 `finish()`。
2. 配套的 `@capacitor/app` 插件（负责把 `backButton` 事件转发给 JS）**没有打进这个 APK**
   （`assets/capacitor.plugins.json` 是 `[]`）。
3. 我试过三种原生补丁（override `onBackPressed` → `bridge.getWebView()` / 按 view id 查找 /
   递归遍历视图树），真机实测：这个 APK 里 **`Bridge.getWebView()` 返回 null**，
   视图树里也拿不到那个 WebView 实例，最后一种实现还会在 `canGoBack()` 上抛 NPE。

**当前状态**：原生补丁已全部回退（避免崩溃风险），只保留 JS 侧的修复 ——
**应用内左上角的 `‹` 返回是好的**（之前它也会因为 `history.replaceState` 不产生历史而失效，
现在改成 `pushState` + `popstate` 已经正常）。

**要彻底修好**需要重编原生层（加 `OnBackPressedCallback` 并持有 WebView 引用），
或者把官方仓库的 `desktop-tauri/mobile/android` 用 Android SDK 完整构建一次 ——
两条路都需要能跑 gradle 的环境，本次没做。

---

## 4. 已知限制

- **硬件返回键会退出应用**（见 3.3，上游 Capacitor 的结构问题，需重编原生层才能修）。
- **必须卸载官方版**再装：签名是你自己的 key（见第 5 节「签名」）。
- **不做局域网扫描**：只探环回。连别的机器请手填地址（原逻辑不变）。
- **不暴露「局域网访问 / 开放面板」两个开关**：它们在桌面端要写应用配置并**重启网关**，
  手机上做这件事需要改 `env.sh`（`AGENT2API_HOST`）并 `ctl restart`，属于模块侧的活，
  放进 App 里会做出「拨了没反应」的假开关。
- **新增文案只有中文**：i18n 词典没有扩充，非中文语种下这一块回落中文原文。
  （词典源在 `desktop-tauri/i18n/i18n-src/<locale>/settings.json`，加 key 后跑 `build.mjs` 即可补。）
- **上游更新会覆盖**：`ctl update` 只换服务端二进制与 `ui/`，不动 APK；
  但下次装官方新 APK 会变回原样，需要重新打这个补丁。

---

## 5. 自己重建

```bash
cd desktop-tauri/mobile
npm ci
# 注意：本机 esbuild 被安全策略拦了文件读取，需要把 esbuild.exe 复制到可读目录再指过去
cp node_modules/@esbuild/win32-x64/esbuild.exe "$TEMP/esb2.exe"
ESBUILD_BINARY_PATH="C:\\Users\\<you>\\AppData\\Local\\Temp\\esb2.exe" npx vite build --mode apk
# 产物在 desktop-tauri/mobile/android-www/
```

打包（把产物塞回官方 APK，**不签名**）：

```bash
python repack.py \
  --apk   /path/to/Agent2API-<ver>.apk \
  --web   desktop-tauri/mobile/android-www \
  --out   /path/to/Agent2API-<ver>-mod-unsigned.apk \
  --apk-sha256 <官方 APK 的 sha256>   # 可选，防拿错基线包
zipalign -p -f 4 ...-unsigned.apk ...-aligned.apk
```

`repack.py` 里有一条不能动的规则：**`resources.arsc` 必须保持 STORED**，
否则 Android 11+ 直接装不上 —— 这是自己改 APK 最常见的翻车点。

### 签名

**不要把签名私钥提交进仓库。** 本仓库早期版本曾把 `a2a-mod.jks` 连同口令一起
提交（可 `git show <old-commit>:apk-mod/a2a-mod.jks` 取回）——那等于把发布私钥
公开：拿到仓库的人可以签出**同包名、同证书**的 APK，Android 会把它当成正常
升级**静默覆盖**已经装了旧包的手机。所以这把钥匙只能按「已泄露」处理：

- 不能再用它签任何新版本（`apk-mod/sign-tool.sh` 会直接拒绝这个证书指纹，
  指纹常量在同一文件顶部）；
- 已经用旧钥匙装上的手机**不会自动变安全**——签名校验只发生在安装时，
  攻击者签的包同样能通过；用户需要按 `apk-mod/signing.md` 主动换成新签名版本。

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
apksigner sign --ks "$A2A_KEYSTORE" --ks-key-alias "$A2A_KEY_ALIAS" \\
  --ks-pass env:A2A_KEYSTORE_PASS \\
  --out ...-mod.apk ...-aligned.apk
```

跨签名的包**不能覆盖安装**：换钥匙后老用户必须卸载重装（`adb uninstall
com.agent2api.mobile` 之后再装），具体迁移步骤和发版顺序见 `apk-mod/signing.md`。

`*.jks` / `*.keystore` / `*.pass` 已被根 `.gitignore` 排除；任何情况下都不要
为了「方便别人复现」把私钥或口令放进 git（包括示例、截图、CI 日志）。
