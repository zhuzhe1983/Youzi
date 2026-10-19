# Youzi 任务体验与图片尺寸本机验收

2026-10-19；Apple M5 Max、128 GB、macOS；本机预览候选 `candidate-d67949b0`。只更新原生客户端，保留现有签名包中的 0.14.4 runtime；未发布版本。主工作目录原有未提交修改保留，打包前后以二进制 diff 比对。

## 完成内容

- 新建任务页：场景、输入区、专家/技能/连接器引用和工作空间/项目选择。
- 成果：删除确认和系统废纸篓；外部文件只移除引用。
- 模型：按模型自动/手动加载，去除重复的总开关；远程发现成功后自动打开候选列表。
- 图片：工具将合法正整数尺寸就近对齐到本地接口允许的 16 像素倍数，限制在 256–2048；1920×1080 变为 1920×1088。收据包含原尺寸、实际尺寸和告知要求，成果卡片直接显示调整。无二次缩放、重复推理或默认设置修改。

## 验证

使用 `RAPID_DESKTOP_NO_PORT_SWEEP=1`，避免测试结束现有端口服务。

```sh
RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --filter 'Youzi|SettingsRouterTests|SettingsVisualFoundationTests|SettingsDeepLinkRoutingTests|SettingsResponsiveLayoutTests|SettingsVoicePreviewTests|ModelGenerationDefaultsTests|RemoteModelTests|ModelServiceAuthTests|ModelAPIAccessTests|SidecarBuildScriptTests|VoiceCoLoadTests|SessionModelRestoreTests|AutoStartDecisionTests|ImageGenViewModelTests|VideoGenViewModelTests'
```

467 tests / 65 suites 通过。包括图片工具/收据 32 项专项检查，删除的所有权、路径、失败恢复与记录保留，以及自动启动、手动加载保护、模型发现和输入区引用。

原生检查：金融场景改变示例；加号显示文件、专家、技能、连接器；专家出现在工具栏，技能显示可移除标签；工作空间/项目位于输入区下方。成果菜单可打开删除确认并说明系统废纸篓。未自动确认删除用户文件。

设置中 Qwen Image 显示已就绪且策略为自动加载，旧优选清单总开关和立即加载按钮均已移除。既有网关读取到 100 个模型、10 个图片候选，列表自动弹出；选择后两处名称同步，随后取消临时表单。未保存测试配置、修改凭据或发送远程生成请求。

安装后本地 OpenAI SDK：模型列表包含 Qwen Image 2.1，非流式与流式 Responses 成功，模型详情匿名访问和错误 Bearer 返回 401；服务连续约 61 秒保持 ready。完整 app 的 deep/strict 代码签名和可执行文件 rpath 检查通过。

本轮未额外运行 GPU 图片生成；尺寸转换、单次请求和告知信息由工具层测试验证。旧任务中的失败消息作为历史保留，需要再次提交生成请求才能获得图片。

## 备份与恢复

更新前的完整应用、运行时覆盖目录、偏好和未提交 diff 保存在本机 `~/Library/Application Support/Youzi/Client Backups/task-experience-*`。验收日志及工作树清理记录随该备份保存。正常退出应用后，可用该目录里的旧 app 替换当前预览 app；无需回退模型文件。工作树只在确认合并、干净且无进程使用后移到系统废纸篓，分支保留。

## 后续范围

设置内的实际 MCP 配置尚未迁至专家/技能/连接器管理页；需要迁完连接配置、状态与认证能力后再移除旧设置入口。当前输入区延用既有引用语义，没有新增专家团调度或连接器认证流程。
