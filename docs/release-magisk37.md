# v3.4.1 / magisk.37 发布说明

## 下载与升级
- [Magisk / KernelSU 模块](https://github.com/84593320z/agent2api-magisk/releases/tag/v3.4.1-magisk.37)，versionCode `2026110437`，安装包 `agent2api-magisk-v3.4.1-magisk.37-arm64.zip`。
- [手机端 APK 3.4.1-mod](https://github.com/84593320z/agent2api-magisk/releases/tag/apk-v3.4.1-mod) 保持原产物和证书，无需为此修复重装 APK。
- 已发布 magisk.36 与全部历史附件保留；新版本通过版本号清晰区分。

## 修复
1. 官方插件的 glibc PT_INTERP 在 Android 缺失，原启动前扫描赶不上安装后立即 spawn。现在只对 server 使用 loader-local preload，同步桥接受控 ARM64 插件，不改官方插件字节及签名，不设置全局 LD_PRELOAD。
2. supervisor 建立并导出模块运行 TMPDIR；状态 JSON 采用 printf 原子写，消除该路径的 here-doc 隐式临时文件。
3. fallback 安装器使用独立安装暂存变量，避免 source customize 后清理错运行目录。
4. 保留此前事务恢复、DNS 原子身份、手机端 epoch/严格回显修复；服务端及 UI/运行库不变。

## 验收
- 541 项行为/集成检查和 19 项 Shell 语法检查通过；[magisk.37 发布前重跑与打包证据](magisk37-20261104/release-validation.json)。
- 真机六种 spawn/exec 入口、ENOENT/EACCES 负对照、连续 50 次 spawnp 通过。
- 真机官方 providers 3.4.1 / web providers 3.4.2 安装及握手通过；主动服务重启后两个 host running、crashes=0、lastError=null，官方包字节与签名保持。
- 覆盖服务重启与插件握手；整机重启和每账号模型转发不作为此次验收结论。
- [完整手机修复报告及证据](phone-fix-20261104/2026-11-04_手机修复验收-agent2api-report.md)保留部署时 magisk.36-phonefix 的原始历史记录；本次发布仅新增 magisk.37 元数据、文档和发布前核验，生产修复字节一致。

## 安装与复现
在 Magisk / KernelSU 安装模块 ZIP 并按管理器提示操作；保留既有配置。附件 SHA256SUMS.txt 可用于校验下载。当前已修复的测试手机不需要为版本号单独重复刷入。

```bash
python pack.py
NODE_BINARY=node PYTHONIOENCODING=utf-8 sh test/run.sh --full
python test/verify_upgrade_3_4_1.py
python test/build_plugin_bridge.py --zig /path/to/zig
```

桥接固定 Zig 0.13.0、aarch64-linux-gnu.2.17；覆盖边界及回滚备份记录见完整报告。补丁基线为已发布 `adf3690643c5da649e523acbd396048e14679b55`。
