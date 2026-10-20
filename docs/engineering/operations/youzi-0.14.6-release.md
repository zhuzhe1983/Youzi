# Youzi 0.14.6 发布记录

负责人：Atlas 集成与发布，Pixel 负责桌面验收，Harbor 负责打包流程。
本机执行，角色文件缺失。用户已授权本次 0.14.6 发布。

## 当前阶段

2026-10-20 已完成构建、独立验收和公开发布：
[Youzi 0.14.6](https://github.com/zhuzhe1983/Youzi/releases/tag/youzi-v0.14.6)。
GitHub 标记为最新正式版，非草稿、非预发布；六个发布文件已回下载并逐个核对 SHA-256。
没有安装或替换用户当前运行的应用。

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
目标 tag 为 `youzi-v0.14.6`。本次通过本地 `gh release create --notes-file`
读取同一源码提交的版本说明，没有触发上游 `rapid-mac-v*` 发布流程。
GitHub OAuth 不含 `workflow` scope，推送工作流文案更新被拒绝；因此保留原工作流。
其草稿说明仍是旧模板，未来使用该工作流时需要先更新授权或人工替换说明。
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
Ruff lint、format 与 `git diff --check` 通过。曾用临时目录与假的 `gh`
验证草稿脚本，但工作流改动因上述授权限制未纳入最终发布。
这些是元数据与脚本验证，不代表真实构建或 GitHub 草稿已执行。

## 最终源码与回归验证

发布标签 `youzi-v0.14.6` 精确指向
`520bcbc2b339236113695a48d5f7b5cd5f7db131`，该提交已进入远端 `main`。
本记录的发布后更新不改变标签或安装包对应的源码。

- 独立 Python 协议及 Youzi 回归：2603 项通过、32 项跳过。SDK 和已记录格式边界的
  跳过项不计作通过。定向测试与全套回归有重叠，不叠加宣称测试总数。
- 集成 Swift Testing 报告 80 个套件、598 项测试，测试运行通过；日志明确列出
  19 个跳过项。另有 8 项 XCTest 通过。可选视觉及真实服务测试没有开启，
  不能据此宣称已完成新的界面操作验收。
- 源码和文档验收、最终产物验收均由独立审查者完成，两个验收结果均为 `passed`。
  最后一次源码调整只恢复无权修改的 Actions 工作流并修正发布流程说明；
  运行代码保持不变，重新从最终提交构建、打包并验收。

本次原开发 checkout 中的 20 个已有修改文件摘要保持不变。为保留重叠的未提交工作，
没有在该脏 checkout 上强行更新本地 `main`；发布集成已在远端 `main` 完成。

## 最终构建与真实运行检查

在 Apple Silicon 本机从上述干净提交构建，包含完整 sidecar，不捆绑可独立使用的
模型 checkpoint。运行时保留 mlx 0.32.2、mlx-lm 0.31.3、mlx-vlm 0.6.17、
mflux 0.20.0、mlx-audio 0.4.3、mlx-video-with-audio 0.1.36。

最终包内 CPython 从隔离目录运行，禁用用户 site-packages 和字节码写入；
聊天、图片、音频和视频模块导入通过，Metal 数组计算通过。
离线图片测试通过最终 sidecar 的真实 HTTP 服务执行：

- 模型：`mlx-community/Qwen-Image-2.1-mflux-q4`；
  固定 revision：`746a58556820933a2df5c75887a2570f1ad200c0`。
- 只使用已有本地缓存，禁用网络权重获取；随机 loopback 端口，仅清理测试创建的进程。
- 返回 HTTP 200，解码并确认非空白的 512×512 PNG，269157 字节，60.63 秒。
  这是运行检查，不是跨后端性能比较或默认速度承诺。

未进行新的 GUI 安装操作、macOS 14 实机执行、麦克风与音频试听、远程服务调用、
通用文本/VLM 实际推理或视频生成测试。这些能力不能由模块导入或 mock 测试外推。

## 产物与公开下载验证

最终应用及 DMG 内应用均通过 `codesign --verify --deep --strict`，
资源检查和搬移后的模板解析检查通过，DMG 自身校验通过。
签名为 ad-hoc，未经 Apple 公证，不宣称 Gatekeeper 已认可。

独立审查逐一匹配包内 428 个项目 Python 模块与源码。
ZIP、DMG 各 13267 个文件或链接条目与最终应用一致；
sidecar 归档 13121 个条目与最终运行时一致，含摘要、链接目标和执行权限。
没有用户设置、私有凭证文件或外部符号链接。
mflux 附带一个 594008 字节的静态 embedding tensor，与依赖 wheel 的 RECORD 一致；
这是库资源，不是独立模型 checkpoint，不能把本包描述为完全没有 tensor 文件。

已发布并从公开下载地址重新读取验证的文件：

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
| `Youzi-macos-arm64.dmg` | 303977588 | `1767a95cd98d6f502d2eebed1487a979a4b828f604c9581a400f15feb05969a2` |
| `Youzi-macos-arm64.zip` | 204608469 | `4d1d89bd585dcc462353cc468781da8df333e460328d8c39995f31c7d31acc97` |
| `rapid-mlx-sidecar.tar.gz` | 166433422 | `aadb1d178d0687760266cdcd9050f2e15cadab2a474add4f8962b363294817dd` |

另包含 `latest.json`、`build-info.json`、`SHA256SUMS`，三者也完成回下载验证。
版本清单、源码标识、发布标签、GitHub Latest 和下载大小/摘要均相符。
原始日志、两个独立验收包、完整下载验证结果和工作树恢复记录保存在本机
`build/reports/upstream-0146/`，不将机器路径、原开发补丁或原始日志提交到仓库。
