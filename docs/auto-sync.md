# 上游自动同步、构建与发布

## 使用

[Actions → Upstream sync, build and release](https://github.com/84593320z/agent2api-magisk/actions/workflows/upstream-sync.yml) 每小时第 17 分钟检查上游正式 Release；GitHub 调度实际执行时间可能延后。

手动 **Run workflow**：

- `build_current=false`：检查更新；仅版本严格增加时构建并发布。中断发布优先使用原运行制品恢复。
- `build_current=true`：重新构建当前版本、执行测试、使用既有证书签名并保存 artifacts，**不提交、不创建或覆盖 Release**。
- `publish_current=true`：没有待发布的正常上游更新时，按当前上游版本做一次维护重发，`module_revision` 增加 1，`mobile_versionCode` 不变；若已有正常上游同步计划，则优先正常同步。只产生新的 `magisk.N`，不虚构上游或 APK 新版本；以实际签名资产与线上 Release 的比较决定是否复用或受控替换 APK，并保留包名、versionCode 与证书。
- `allow_prerelease=true`：连上游标记为 prerelease 的 beta 一起检查（默认只看正式版）。以 beta 发布时 GitHub Release 同样标为 prerelease；semver 中预发布低于同号正式版，正式版 `X.Y.Z` 出来后仍会再同步。
- 外部通知可调用 `repository_dispatch`，事件类型 `upstream-release`；仍重新读取官方 Release 与 tag，不相信事件中的下载地址。

## 执行链与权限

1. **detect**：默认只取正式数字三段版本，`allow_prerelease` 打开时才接受 `X.Y.Z-pre` 形态的预发布；按 semver 优先级比较，已同步的 beta 不会被旧正式版回退；记录 tag、解析后的完整 commit、arm64 资产 SHA-256/大小及 Release 时间。同步游标位于 [配置](../scripts/autoupdate/config.json)。
2. **selftest**：自动化单元测试及模块完整行为回归。
3. **fetch**：使用只读令牌取得钉死源码与归档；临时认证通过环境注入，不保存至 Git 配置；完整源码传输有磁盘与时间限额。
4. **build**：独立无凭据 runner，融合七文件 mobile overlay，保留上游其余页面；构建 Web/Capacitor/unsigned APK。服务端验证安全归档、ARM64 ELF 依赖与强符号闭包、版本及确定性 ZIP，保留运行库、事务/DNS 修复和插件/runtime 桥接。更新候选树后再次跑完整回归。
5. **sign**：全新 runner，仅运行仓库签名脚本与 Android 官方工具，不执行上游 npm/Gradle。核对包名、版本、Web 资源、APK v2 签名与固定既有证书。
6. **publish**：仅该 job 获得 contents 写权限；维护重发先把新签名 APK 轨与线上 Release 逐资产比对，候选路径白名单与固定配置键校验后再提交或恢复候选 checkpoint。两个 Release 逐资产上传并回下载核 SHA-256，完整后再以独立 docs commit 更新 README 自动版本区及根目录 `update.json`。普通 Release 的既有同名资产只核验、不覆盖；只有同上游版本的 APK 维护重发可以按实际资产差异受控替换。后续 detect 同时核对 Release 与文档入口，文档提交失败或取消也会恢复原计划的幂等发布。
7. **failure**：仅提交脱敏故障记录至 `automation/failure-<tag>` 并创建/复用 PR，附 Actions 日志入口。候选代码与原始日志不写入故障 PR。

并发组 `upstream-sync` 串行运行；失败不会自动跳过检查。源码提交之后中断，由配置中的 `last_plan` 定位原 Actions artifacts、checkpoint commit 和原 tag，避免重新签名产生不同 APK。重试可以从旧 checkpoint 检出，但要求它仍是最新 main 的祖先；文档提交前只快进到最后 main，拒绝分叉历史。artifact 已过期或旧资产被篡改时，检查会保持失败并提供故障记录，而不是覆盖发布。

## 发布可靠性与维护重发

以下规则由发布代码和故障注入测试约束；是否已在某个 Release 上执行，以实际部署记录为准：

1. **发布完成后再更新文档入口**：模块与 APK Release 的资产均上传并回下载核验后，再用独立 docs commit 更新 README 自动版本区与 `update.json`，避免更新入口提前指向尚未完整发布的资产。
2. **同上游版本的 APK 维护重发**：维护重发直接比较新签名 APK、`signature.json`、校验和与线上 Release，不能用候选 manifest 推断——overlay 修复可能已经在 baseline 中。资产完全一致则复用原 APK 轨；有差异才允许在原有 `apk-vX.Y.Z-mod` Release 上替换变化资产，保持同一上游版本、包名、versionCode 和固定证书，全部回下载核验后才移动 tag。线上出现计划外资产时，在任何 checkpoint 或 Release 变更前失败。
3. **验收前不外推**：单元测试、真实发布演练和真机验收是不同证据层级；任何一层通过都不能替代其余层级。

## 签名配置

仓库 Actions Secrets：

| Secret | 用途 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 既有 mod keystore 的 Base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 既有 alias |
| `ANDROID_KEY_PASSWORD` | 既有私钥密码 |
| `UPSTREAM_READ_TOKEN` | 可选；上游私有时使用，仅需读取上游 |

固定证书 SHA-256：`d0ca6713c4aeaa4ad05b3610bee3e0f87379f428f59ba4b85e514a25bb46b15f`。四项 Android Secret 已使用仓库公钥加密配置，私钥不入库、不作为 artifact。默认 GITHUB_TOKEN 只读；publish/failure 按 job 提升所需权限。

## 输出及复验

- `sync-plan`：来源与恢复标识。
- `baseline-regression`：基线全回归日志。
- `unsigned-candidates`：模块 ZIP、未签名 APK、候选 source bundle、provenance、ELF/手机资源检查、更新后回归日志。
- `signed-apk`：同证书 APK 与签名摘要。
- 自动发布模块 tag：`v<version>-magisk.<revision>`；手机 tag：`apk-v<version>-mod`；两个 Release 各自包含独立校验清单。

```bash
python -m pip install pyelftools==0.32
python -m unittest discover -s test -p 'test_autoupdate*.py' -v
sh test/run.sh --full
```

模块 revision/datecode 与 mobile versionCode 只增不减；同上游模块维护重发不改变 mobile versionCode。超过当前编号范围、上游 ABI 不兼容、补丁冲突、资源不一致、签名不符都会进入失败记录。CI 不连接手机：账户模型请求、系统重启与新版本实际设备运行仍属于真机验收，不由离线通过替代。

## 模块与 APK 的更新入口

- `module.prop` 的 `updateJson` 指向 `https://raw.githubusercontent.com/84593320z/agent2api-magisk/main/update.json`，发布链写入 `version`、`versionCode`、模块 ZIP 下载地址和 SHA-256。**仓库现已公开**，具备由 Magisk 管理器匿名读取 raw URL 的条件；实际检查、下载和安装更新仍需在当前 Release 上做设备验收。
- `a2a update` 仍然只升级服务端与面板。仓库已公开，手机端可在 root 下运行 `a2a apk-update [X.Y.Z]`：缺省取当前模块的上游版本，从对应 `apk-vX.Y.Z-mod` Release 下载 `SHA256SUMS.txt` 与 APK，校验一致后执行 `pm install -r`。镜像与 curl/TLS 降级复用 updater；签名冲突由 Android 明确拒绝，不能强行覆盖。公开仓库提供了匿名下载条件，但离线命令测试不等于该端到端设备链已经验收。
- APK 不塞进模块 ZIP：模块 ZIP 在独立签名 job 之前确定性构建，而 APK 必须稍后使用既有证书签名。把签名后的 APK 回塞 ZIP 会破坏这条构建/验收顺序；独立 Release + 设备端校验安装保持两条制品链清晰。

## 部署记录

### 早期自动化上线

早期实现从 magisk.37 的已发布提交 `185b17bfde6d884cd2c2bf90ecc4a4dbb8a084a7` 起步；历史模块及 APK Release 保留。

| 提交 | 内容 |
|---|---|
| `a27dcab` | 自动化脚本与工作流上线，Actions 启用、默认只读、四项 Android Secret 已加密配置 |
| `0b5fa40` | 覆盖上游 `mobile/android/gradle.properties` 写死的 Windows JDK 路径（命令行 `-Dorg.gradle.java.home` 优先） |
| `1a6a9dd` | 候选 module 元数据保真：保留 description 手写说明（仅滚动 `载荷 vX.Y.Z`，r18 依赖）、保留 `seed/VERSION` 注释/键序/`commit=` |

| 运行 | 历史结论 |
|---|---|
| [41846700236](https://github.com/84593320z/agent2api-magisk/actions/runs/41846700236) | 首次真实运行：detect/selftest/fetch 通过，build 因上述 JDK 路径失败；failure job 自动创建 [PR #1](https://github.com/84593320z/agent2api-magisk/pull/1)（仅脱敏故障记录），sign/publish 跳过，历史 Release 未动 |
| [41848561601](https://github.com/84593320z/agent2api-magisk/actions/runs/41848561601) | 修复后 smoke（`build_current=true`）：build/sign 通过，publish 按 smoke 语义跳过；制品离线复验 APK 证书、Web 资源、provenance/ELF 均 PASS，全回归通过 |
| [41915346028](https://github.com/84593320z/agent2api-magisk/actions/runs/41915346028) | 每小时调度：同版本游标下仅 detect/selftest 运行，构建与发布全部跳过，无副作用（幂等已实测） |
| [41955097236](https://github.com/84593320z/agent2api-magisk/actions/runs/41955097236) | 元数据保真修复后 smoke：模块 ZIP 成员/CRC、`metadata_fidelity=true`、description、`seed/VERSION` 注释与固定上游 commit 均通过检查，APK SHA 与证书保持预期 |

v3.4.2 / magisk.38 随后完成真实 publish，两条 Release 均已生成。这是 README/update.json 随发布同步的早期部署节点；中断后跨运行恢复已有单元测试与本地演练。

### 3.5 beta 同步与维护重发

| 运行 | 同步/重发记录 |
|---|---|
| [42753934443](https://github.com/84593320z/agent2api-magisk/actions/runs/42753934443) | `c55fe36`：显式开启预发布后首次同步上游 v3.5.0-beta.1，模块为 magisk.39，APK 为 3.5.0-beta.1-mod / versionCode 30500 |
| [42790043366](https://github.com/84593320z/agent2api-magisk/actions/runs/42790043366) | `ad9a02d`：同一上游版本的维护重发，模块升至 magisk.40，包含 KernelSU standalone BusyBox 的 mkdir 兼容修复；mobile versionCode 不变 |
| [42952807126](https://github.com/84593320z/agent2api-magisk/actions/runs/42952807126) | `964898e`：同一上游版本再次维护重发，模块升至 magisk.41，加入 Bun runtime spawn bridge；APK 仍为 3.5.0-beta.1-mod / versionCode 30500 |
| [42973753655](https://github.com/84593320z/agent2api-magisk/actions/runs/42973753655) + [42980041777](https://github.com/84593320z/agent2api-magisk/actions/runs/42980041777) | `c31ca7d` checkpoint / `a9fb575` docs：完整构建、签名及回归通过；两次发布恢复分别修正实际 APK 资产比较与旧 checkpoint 后代 main 恢复，最终 magisk.42 和更新后的 APK 轨均发布并回下载核验，文档最后提交 |

当前发布为 [`v3.5.0-beta.1-magisk.42`](https://github.com/84593320z/agent2api-magisk/releases/tag/v3.5.0-beta.1-magisk.42) 与 [`apk-v3.5.0-beta.1-mod`](https://github.com/84593320z/agent2api-magisk/releases/tag/apk-v3.5.0-beta.1-mod)，上游精确源码为 `aba58858c7f3ae695c5e71d388d7d0e31c7dd7cf`。magisk.42 包含本轮模块、发布链与 APK 自动发现修复；APK 上游版本和 versionCode 仍为 3.5.0-beta.1 / 30500，没有虚构新的上游或 APK 版本。

### 真机边界

- magisk.37 的 providers 3.4.1 / web 3.4.2、六入口与连续 spawnp 等结果属于历史特定版本，不能外推为当前 3.5 beta 的全量回归。
- mkdir 缺陷曾在 KernelSU 3.3.1-44 / OnePlus PJZ110 上做命令级实测；这不等于 magisk.42 的安装、运行、Bun runtime 与更新链已完成整机验收。
- 当前 APK 的安装/覆盖安装、启动、自动发现、开关同步、硬件返回键与网络切换仍需在当前 Release 上验证。CI 的构建、签名、资源核验及离线命令测试均不连接手机。
- 仓库公开只消除了私有 raw/Release 资产的匿名访问限制；Magisk `updateJson` 更新与 `a2a apk-update` 仍需当前版本真机端到端验收。
