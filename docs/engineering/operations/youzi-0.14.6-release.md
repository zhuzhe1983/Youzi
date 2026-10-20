# Youzi 0.14.6 发布记录

负责人：Atlas 集成与发布，Pixel 负责桌面验收，Harbor 负责打包流程。
本机执行，角色文件缺失。用户已授权本次 0.14.6 发布。

## 当前阶段

已准备可审阅的版本元数据与发布说明，尚未在本记录中宣称打包、安装或公开发布完成。
最终源码、测试结果、签名与资源检查、产物摘要、GitHub 发布地址及回退位置，
须由 Atlas 在实际验收后追加。

版本来源为 `pyproject.toml` 的 `[project].version`，应用的
`apps/rapid-mac/Resources/Info.plist` 同步为 0.14.6；`CFBundleVersion` 为 176。
Python `__version__` 从安装包元数据读取，不另加硬编码版本。

## 本次范围与来源

保留现有依赖、`vllm_mlx` 命名空间和模型范围，只按现有架构选择性回移修复。
没有新增模型支持或新的 benchmark 结论。

| 修复范围 | 上游来源 |
| --- | --- |
| 单请求 KV 缓存弱引用与必要垃圾回收 | #4111，`a6e02b3c8` |
| ASR、翻译与对齐上传容器后缀 | #4410，`a9eab3bc0` |
| 多模态重复输出终止与有效部分回答 | #3291，`e86a6a939` |
| 多模态 seed / top_k / min_p | #3496，`813a2f6c6`，补齐旧架构的参数贯通 |
| 社区检查点工具解析器选择 | #4099，`20766e0af` |
| 原生 XML 必选工具 | #4432，`9cdca6a78` |
| 原生模板工具语法与自动语法拒绝路径 | #4876，`28bbd6bb4`；#4928，`abb927d09` |
| 无工具请求保留普通内容 | #4887，`25d474a4e` |
| 流式工具标记跨片段处理及 logprobs 归属 | #4950，`2619e8750`；#4960，`58d557b73` |
| 工具调用截断时保留 length 结束原因 | #4715，`1762fe176` 的路由与后处理部分；不含该提交的引擎 MRoPE 更改 |
| 中断回复、切换后标题更新 | #4940，`0c2de4835` |
| 私有存储文件创建权限 | #4904，`7df53b10a` |
| 图片请求在加载权重前校验 | #4573，`8f076c197` |

另包含 0.14.5 发布后已进入 main 的设置界面简化与远程密钥存储修复：
`c408981b0`、`e372f30e7`、`529858858`，以及对应验收记录。
远程模型密钥使用 Youzi 设置；旧钥匙串只做一次非交互迁移尝试，
不可读取时要求重新填写，不恢复交互授权入口。

Runtime adapter 文档属于未来提案，不作为本次已交付功能。

## 发布说明与打包

对用户的说明为 `docs/release-notes/youzi-v0.14.6.md`，桌面 CHANGELOG 指向相同版本。
`scripts/youzi-release-manifest.py` 从最终应用版本选择对应 Youzi notes，
不再复用硬编码的 0.14.5 功能摘要；缺少历史或未来版本 notes 时使用带实际版本的
通用说明，空 notes 文件则报错。应用、内置 runtime 和 sidecar 归档版本必须一致。

沿用 `.github/workflows/youzi-package.yml` 和 0.14.5 的 Youzi 发布路径，
目标 tag 为 `youzi-v0.14.6`。草稿流程从同一源码提交检出对应 notes，
通过 `--notes-file` 创建草稿；本次没有触发上游 `rapid-mac-v*` 发布流程。
仅 Apple Silicon、ad-hoc 签名，未经 Apple 公证；完整运行时随包分发，不含模型权重。

Atlas 应从最终集成提交构建完整应用，并在确认版本、源码标识、签名、资源、
runtime、DMG、归档与摘要一致后发布。同一 Swift scratch 目录的构建与测试串行运行，
原生检查保持 `RAPID_DESKTOP_NO_PORT_SWEEP=1`。

回退沿用 [0.14.5 发布记录](youzi-0.14.5-release.md)：备份完整应用、设置与数据，
只替换完整签名应用；不清除模型缓存，不用旧快照覆盖新会话。
密钥迁移后的新增或修改不会回写旧钥匙串，回退时须保留对应设置备份。

## 元数据准备验证

Python 3.12.13 / pytest 9.1.1，使用独立测试环境，未安装或替换应用：

```sh
/tmp/youzi-0146-test-venv/bin/python -m pytest \
  --noconftest -c /dev/null -p no:cacheprovider \
  tests/test_youzi_release_manifest.py tests/test_version_sync.py -q
/tmp/youzi-0146-test-venv/bin/python scripts/check_version_sync.py
```

Manifest 与版本同步共 33 项测试通过，检查器确认 0.14.6 一致。
Ruff lint、format 与 `git diff --check` 通过。另用临时目录及假的 `gh`
执行草稿脚本，确认 notes 来自对应版本文件、目标源码参数保留，
notes 缺失时不调用 GitHub CLI；所有 workflow shell 段通过 `bash -n`。
这些是元数据与脚本验证，不代表真实构建或 GitHub 草稿已执行。
