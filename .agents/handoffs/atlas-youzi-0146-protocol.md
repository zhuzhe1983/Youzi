# Youzi 0.14.6 工具协议回移

Atlas 在 Local Mac 集成；分支 `release/youzi-0.14.6`，以 `7992b761` 为基线。
角色文件目录不存在，沿用仓库 AGENTS.md 的集成与发布职责。

## 来源和范围

- `20766e0af` / #4099：Qwen3.8 checkpoint 名称与元数据共同决定原生 XML 工具解析，不把目录组织名误当架构。
- `9cdca6a78` / #4432：forced tool prefix 按实际服务的模板渲染决定；required/named 结束后没有合法调用则明确报错。
- `28bbd6bb4` / #4876、`abb927d09` / #4928：auto grammar 尊重模型原生 wire，超大 schema 的原生格式探测有单独上限，并沿用有界后台编译池。
- `25d474a4e` / #4887：没有声明工具的请求不解析或返回可执行调用；文本、结构化通道以及三类兼容接口一致。
- `2619e8750` / #4950、`58d557b73` / #4960：增量内容净化保留分块边界状态，工具边界前释放普通文本，logprobs 随对应内容一起发送。
- `1762fe176` 中 #4715 的 route/postprocessor 部分：达到 token 上限仍报告 length，不升级成完成工具调用。未引入该提交的 MRoPE 引擎改动。
- 配合内存工作流更新 helper 的 503 原因区分。

## 兼容适配

保留 `vllm_mlx` 包名、Youzi telemetry、错误恢复、依赖版本。
没有引入上游后续 inference telemetry 模块；新错误分支在发送明确 SSE 错误后直接结束。
结构化调用与同块 narration 的处理取其必要语义，不导入整个后续 Nemotron authorization 重构。
上游测试中仅针对该重构的 private dropped-call 状态断言已移除；保留无工具时不调用 parser、完整响应内容、空调用和结束原因的断言。
缺失的 qwen35 模板 fixture 从同一上游提交导入，用于离线精确模板测试。

回归记录与最终结果在本次发布操作文档中归档。下一步是完成集成测试、独立验收和精确源码打包，未验收前不得发布。
