# Atlas → Atlas / Vector / Pixel / Harbor：多运行时提案

日期：2026-10-20。负责人 Atlas，Local Mac。分支 `docs/youzi-runtime-options`，
基线 `7992b7611342c283aea8bbc8d32abd9c35afa466`，无 PR。
已阅读 AGENTS.md；本 checkout 不含 `.agents/roles/`，未虚构角色文件要求。
研究在独立 worktree 完成，未读取其他任务的未提交实现作为共享状态。

交付：[Youzi 多运行时接入与性能选优提案](../../docs/engineering/decisions/2026-10-20-youzi-runtime-adapters.md)。
状态为 proposed；本次只写文档，无安装、权重下载、加载、推理、实现、部署或发布。
没有改动现有 0.14.6 修复及应用配置，也没有产生新的性能排名。

已核实：

- 阅读现有原子目录/身份/执行契约、模型管理与公开发现、远程边界、当前 GUI 单一偏好源码。
  提案保留每工作流一个首选、只自动加载首选本地模型和 loaded-only 公开 API。
- 官方 README、管理/支持文档、源码和 LICENSE 按 commit 固定；读取 GitHub 最新发布元数据。
  候选包括 oMLX、mlx-lm/vlm/audio、llama.cpp、Ollama、vLLM Metal、Splash、exo。
- oMLX 可使用独立 Splash 引擎，报告必须区分原生与代理路径；Ollama 官方 Qwen3.8 标签
  已包含 MLX 和其他量化路径，不能沿用只支持 GGUF 的假设。
- vLLM Metal 明确举例的是 Qwen3.8-27B 8-bit；各引擎是否能直接读取当前 Rapid-MLX
  4-bit-MTP artifact 仍待验证。未把架构支持、项目宣传或已有旧 benchmark 当成本轮验收。
- 文档区分同文件运行时比较与不同量化/格式的产品比较，定义 TTFT、完整任务延迟、
  内存、质量/格式、缓存、并发、取消与稳定性门槛；推荐阈值明确标为建议。

未决与风险：

- 外部运行时的自动加载、TTL/LRU 淘汰与当前加载策略有冲突，能否受控仍需契约实验。
- 目标 MTP 文件布局、工具/reasoning/取消语义、Ollama 文件映射、实际打包体积均未实测。
- 主分支资料可能晚于最新 release；实际接入须锁定发布包与依赖，不能混用能力声明。
- 本地依赖版本相互不同，禁止在当前 Rapid-MLX 侧车环境里直接升级成一个大环境。

验证：仅文档与引用核查；检查本地相对链接、引用定义、Git diff 空白/范围及敏感内容。
没有运行应用测试或硬件 benchmark，未声称通过发布验收。

下一步：Atlas 单独审阅/整合提案；Vector 冻结目标 artifact 与测试矩阵并安排隔离实验；
Pixel 审查统一列表和可选高级引擎呈现；Harbor 评估包清单、签名和完整回退方案。
首个实现阶段仅抽出 Rapid-MLX 适配边界，随后再验证 oMLX 原生路径。
本任务按要求只提交，不 push、merge 或 release。worktree 在整合前保留，不满足已合并清理条件。
