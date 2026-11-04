# 上游自动同步、构建与发布

## 使用

[Actions → Upstream sync, build and release](https://github.com/84593320z/agent2api-magisk/actions/workflows/upstream-sync.yml) 每小时第 17 分钟检查上游正式 Release；GitHub 调度实际执行时间可能延后。

手动 **Run workflow**：

- `build_current=false`：检查更新；仅版本严格增加时构建并发布。中断发布优先使用原运行制品恢复。
- `build_current=true`：重新构建当前版本、执行测试、使用既有证书签名并保存 artifacts，**不提交、不创建或覆盖 Release**。
- 外部通知可调用 `repository_dispatch`，事件类型 `upstream-release`；仍重新读取官方 Release 与 tag，不相信事件中的下载地址。

## 执行链与权限

1. **detect**：仅正式数字三段版本；记录 tag、解析后的完整 commit、arm64 资产 SHA-256/大小及 Release 时间。同步游标位于 [配置](../scripts/autoupdate/config.json)。
2. **selftest**：自动化单元测试及模块完整行为回归。
3. **fetch**：使用只读令牌取得钉死源码与归档；临时认证通过环境注入，不保存至 Git 配置；完整源码传输有磁盘与时间限额。
4. **build**：独立无凭据 runner，融合七文件 mobile overlay，保留上游其余页面；构建 Web/Capacitor/unsigned APK。服务端验证安全归档、ARM64 ELF 依赖与强符号闭包、版本及确定性 ZIP，保留运行库、事务/DNS修复和插件桥接。更新候选树后再次跑完整回归。
5. **sign**：全新 runner，仅运行仓库签名脚本与 Android 官方工具，不执行上游 npm/Gradle。核对包名、版本、Web资源、APK v2 签名与固定既有证书。
6. **publish**：仅该 job 获得 contents 写权限；候选路径白名单与固定配置键校验后提交 main。两个 Release 先 draft，逐资产上传并回下载核 SHA-256，完整后公开；既有同名资产只核验，不删除重传。
7. **failure**：仅提交脱敏故障记录至 `automation/failure-<tag>` 并创建/复用 PR，附 Actions 日志入口。候选代码与原始日志不写入故障 PR。

并发组 `upstream-sync` 串行运行；失败不会自动跳过检查。源码提交之后中断，由配置中的 `last_plan` 定位原 Actions artifacts、checkpoint commit 和原 tag，避免重新签名产生不同 APK。artifact 已过期或旧资产被篡改时，检查会保持失败并提供故障记录，而不是覆盖发布。

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

模块 revision/datecode 与 mobile versionCode 只增不减，超过当前编号范围、上游 ABI 不兼容、补丁冲突、资源不一致、签名不符都会进入失败记录。CI 不连接手机：账户模型请求、系统重启与新版本实际设备运行仍属于真机验收，不由离线通过替代。

## 当前部署记录

本次实现从 magisk.37 的已发布提交 `185b17bfde6d884cd2c2bf90ecc4a4dbb8a084a7` 起步；历史模块及 APK Release 保留。真实 Actions 试运行结果在部署验收记录中追加。
