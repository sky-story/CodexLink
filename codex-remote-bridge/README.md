# Codex Remote iOS — Mac Bridge

本目录是当前共享 daemon 分支的 Bridge，基于 RealDyllon/codex-remote 修改并保留 ISC 许可。安装请从仓库根目录的 [README](../README.md) 开始。

**不要通过上游同名 npm 包或 App Store App 安装本分支。** 本分支连接 Mac 已有 Codex daemon 的 Unix socket；原生 CLI 与 iPhone 操作同一活动会话。

在仓库根目录执行：

```sh
npm --prefix codex-remote-bridge ci --ignore-scripts
npm --prefix relay ci --ignore-scripts
node scripts/doctor.cjs
node scripts/private-service.cjs start
```

前提：Codex 已在 Mac 登录并运行、两端 Tailscale 在线。后台服务包含私网 Relay，不要再启动第二套服务。源码更新后用 `node scripts/private-service.cjs restart` 安装新快照。

测试使用 `npm --prefix codex-remote-bridge test`，入口会隔离设备状态和 Keychain。真实状态在仓库外，不要把配对文件或推送密钥放进本目录。

参见 [配置说明](../docs/setup.md)、[验证记录](../docs/validation.md)、[第三方声明](../THIRD_PARTY_NOTICES.md)。
