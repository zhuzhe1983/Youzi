# Atlas：Youzi 应用内更新

接收角色：Atlas / Harbor。任务分支 `feat/youzi-in-app-updates`；功能验收提交
`b62a2ddba`，基线 `f179cdf34`。本次仅交付代码和本地发布工具，没有发布新版本、
替换用户安装包或修改 0.14.6 附件。

## 已完成

- 启用已有 Sparkle 2.9.5：应用内检查、下载、签名验证及标准安装/重启流程。
  默认下载需用户确认，保留已有后台下载偏好。
- 应用内只带稳定公钥；发布私钥使用仓库外的私有文件，不使用 Keychain。
  更新清单及完整 ZIP 均要求签名，解包前验证。
- 本地工具生成并验签 appcast，逐项比对最终 ZIP 与原应用；manifest 阶段
  阻断缺失或版本不符的更新清单。操作见
  [发布文档](../../docs/engineering/operations/youzi-app-updates.md)。

## 验证结果

2026-10-21，Apple Silicon / macOS 27.0.1。构建方 78 项 Swift、48 项 Python
测试通过；独立验收重跑 72 项 Swift、48 项 Python，均通过，实际 Sparkle
联测没有跳过。独立门禁 `20261021-004557-in-app-update-acceptance` 为 passed。

真实 Sparkle 2.9.5 安装器完成临时 App 的版本 1 → 2 替换；损坏 ZIP、错误
ZIP 签名、篡改或未签名 feed 四种反例均被拒绝，旧 App 完整摘要不变。
测试进程、launchd 作业和临时密钥均已清理，没有修改用户应用、设置或模型服务。

原生开发包通过代码签名及资源检查；它使用 debug / SKIP_SIDECAR=1，只验证
桌面构建，不能作为分发包。未验证生产包的运行中退出/重启、更新 UI、受保护
目录权限、生产 CDN 或 Apple notarization，不将这些项目计为已通过。

## 下一次发布

1. 版本号和构建号递增，从发布提交构建含完整 runtime 的应用。
2. 使用既有发布私钥生成签名 appcast，再生成 manifest 与包含 appcast 的
   SHA256SUMS；禁止重新生成密钥或在签名后修改附件。
3. 对可丢弃的完整旧 App 副本验收下载、退出、安装和重新启动，再发布及回读
   验证正式附件。生产发布仍须有明确授权。
4. 0.14.6 缺少公钥，用户需手动安装一次启用新配置的版本。

现有托管 workflow 尚无签名步骤/secret，新的 manifest 检查会阻止它生成
不完整发布。当前完整途径是文档中的本地签名流程；恢复托管打包需由 Harbor
接入受保护的签名环境、签名步骤、appcast 校验和及上传，本次没有修改 workflow。
