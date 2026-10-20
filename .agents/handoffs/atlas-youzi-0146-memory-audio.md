# Youzi 0.14.6 内存、音频与多模态修复交接

接收人：Atlas（集成与发布）。工作分支：`fix/youzi-0146-memory-audio`。
执行环境：Local Mac，独立任务工作树；本分支不执行合并、推送或发布。
仓库没有 `.agents/roles/`，按主代理给定的后端工作范围执行。

## 已完成

- 回移上游 `a6e02b3c8`（#4111）：单请求 KV 缓存表面方法改为弱引用绑定，
  缓存失去最后一个引用后即可释放；保留深拷贝、独立方法拷贝语义。
  内存准入超限时先限频回收循环垃圾，再执行本分支已有的分页缓存释放。
  增加 `MetalMemoryBackpressureError`，区分内存限制与并发限制。
- 回移上游 `a9eab3bc0`（#4410）：转写、翻译与强制对齐保留允许的上传容器后缀，
  无后缀时参考 MIME 类型；未知元数据仍回退 `.wav`。
  区分压缩音频损坏和解码器环境故障，保留临时文件清理与上传大小限制。
  不改变音频内容、采样率、速度或时长。
- 回移上游 `e86a6a939`（#3291）：多模态精确重复输出触发终止时立即移除活跃批次行，
  返回有效的已有输出及 `finish_reason=length`；其他错误仍保留原异常语义。
- 适配上游 `813a2f6c6`（#3496）：在旧架构中补全引擎、调度器、批处理器的
  `top_k`、`min_p`、`seed` 透传。固定种子由每个请求独立持有，预填充与解码共享
  连续随机流；相同参数的无种子请求仍使用批量采样。
  `top_k >= vocab_size` 等价于不截断词表，避免上游采样器抛异常。

保留 `vllm_mlx` 包名与现有运行时依赖，没有引入整套新引擎或生命周期架构。
没有改动主工作树未提交内容、Swift、版本文件、工具协议或图像路由。

## 集成边界

`vllm_mlx/service/helpers.py` 由 Atlas 所有。本分支未修改该文件。
对应 HTTP 503 文案与 `tests/test_backpressure_503_reason.py` 的补丁已单独交给
主代理，主代理已确认应用。集成时必须包含它，以免新的内存异常仍显示为并发超限。

本分支较旧的调度器没有上游的内存感知前缀缓存准入淘汰路径，因此只增加必要的
循环垃圾回收，并保留已有的限量分页块释放。测试也按真实的分页释放入口验证先后顺序。
未引入不存在的 `_note_served_stt_engine`；上游上传测试中的该无关 stub 已移除。
通道能力契约已更新，明确三项采样参数在文本与多模态通道均可用。

## 验证

测试从工作树加载源代码，只读使用已验收的 0.14.5 应用运行时：

```sh
export YOUZI_RUNTIME="/Users/zhuzhe/Workspace/Youzi/apps/rapid-mac/build/Youzi Workspace Preview.app/Contents/Resources/rapid-mlx"
export PYTHONPATH="$PWD:$YOUZI_RUNTIME/site-packages"
export YOUZI_TEST_PYTHON=/tmp/youzi-0146-test-venv/bin/python
```

测试解释器 Python 3.12.13；MLX 0.32.2、mlx-lm 0.31.3、mlx-vlm 0.6.17、
Transformers 5.15.1；pytest 9.1.1、pytest-asyncio 1.4.0、Ruff 0.17.1。
测试工具安装在独立临时虚拟环境，没有改动应用或项目依赖。

- 内存、多模态及相邻回归：493 passed。
- 音频上传、损坏容器、大小限制、对齐与采样透传：139 passed。
- 独立 headless 多模态生命周期进程：13 passed。
- 上述前两组有 10 项采样透传测试重叠，合计 635 个不同测试。
- 所有改动的 Python 文件通过 Ruff lint、format 检查与 `git diff --check`。

复现命令：

```sh
"$YOUZI_TEST_PYTHON" -m pytest -q \
  tests/test_singleton_cache_fastpath.py tests/test_metal_cap_enforcement.py \
  tests/test_prefix_cache_pressure_eviction.py tests/test_paged_cache.py \
  tests/test_hybrid_prefix_cache_growth.py tests/test_metal_memory_budget.py \
  tests/test_mllm_sampling_parity.py tests/test_mllm_penalty_passthrough.py \
  tests/test_mllm_batch_generator.py tests/test_mllm_stats.py \
  tests/test_lane_parity_contract.py tests/test_repetition_guard.py \
  tests/test_mllm_usage_tracking.py tests/test_mllm_executor_cancel.py \
  tests/test_seed_reproducibility.py

"$YOUZI_TEST_PYTHON" -m pytest -q \
  tests/test_audio_upload_suffix.py tests/test_stt_corrupted_file.py \
  tests/test_audio_upload_size_limit.py tests/test_forced_alignment_route_hardening.py \
  tests/test_mllm_penalty_passthrough.py

"$YOUZI_TEST_PYTHON" -m pytest -q \
  tests/headless_mlx/test_mllm_process_loop_errors.py
```

测试包含真实 Metal 数组释放、真实采样器随机流隔离；没有加载大型模型，
音频路由使用引擎 stub 验证文件后缀、完整字节与错误分类，没有宣称实际解码器或模型试听通过。
没有新的架构问题待定；Atlas 下一步应合入本分支与 helper 补丁，运行最终集成验收，
随后按用户授权完成 0.14.6 发布。发布产物验证与回滚仍由集成任务负责。
