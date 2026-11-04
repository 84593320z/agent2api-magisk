# 范围

- 用户目标：将 aimod-cc/Agent2API v3.4.1 服务端与手机端升级合并到本地 agent2api-magisk，保留此前已验收修复并交付产物。
- 基线：84593320z/agent2api-magisk f8e474d59c885e247cbeb179cf2e8f99a4ddbbb4；升级树包含上一轮 repair.patch。
- 上游源码：aimod-cc/Agent2API v3.4.1，3ff4b8215d0d65c3451ca74923e90964ed7dbf59。
- 工作范围：本地源码、官方服务端制品、手机完整源码构建、离线故障注入、静态 ELF 依赖、ZIP 可重现与字节核验。
- 保持不变：原 upstream/repair 工作树、此前 81 份证据、远端仓库与 Release。无 commit、push 或远端发布。
- Android 设备安装、服务启动、DNS/VPN 切换与热安装不属于已观测执行。Shell 用例使用本地生产函数与系统桩；ELF 依赖兼容是离线检查结论。
