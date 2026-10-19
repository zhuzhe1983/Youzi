# 图片尺寸自动调整

智能体调用 `youzi_generate_image` 时，尺寸可以用 `1920x1080`、`1920×1080` 或 `1920*1080` 表示。工具按照本地图片 API 的规则，将宽、高分别调整到 256～2048 范围内最近的 16 像素倍数；恰好居中时向上取整。例如 1920×1080 → 1920×1088，512×530 → 512×528，已经符合规则的尺寸保持不变。

调整在生成前完成，只提交一次请求，不事后拉伸图片，也不改全局默认设置。结果中的 `generation` 带上 `requested_size`、`effective_size`、`size_adjusted` 和告知用户的说明；运行时报告尺寸时优先采用其报告。聊天成果卡片直接显示调整前后的尺寸，智能体也应说明调整。

格式不合法时返回 `invalid_image_size` 和明确说明，中文界面展示对应错误。不再把常见 1080 高度泛化为工具失败，或让智能体原样重复请求。

验证：`RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --filter 'YouziLocalModelToolsTests|YouziChatArtifactTests'`，32 tests passed。此项为客户端参数归一化与回执验证，未运行真实 GPU 出图。
