# Harbor → Atlas：Youzi 签名应用更新发布工具

- 日期：2026-10-21
- 分支：`feat/youzi-update-release-tools`；基线 `origin/main` 的 `f179cdf34`
- 执行：Harbor，本地 Mac 独立工作树；Atlas 负责集成与应用安装验收
- 协作输入：Atlas 的密钥工具提交 `5a9663823` 已 cherry-pick 为
  `5a5d43750`，接口为 `public-key --private-key-file /absolute/path`
- 角色文件：当前 checkout 无 `.agents/roles/`，遵循根 `AGENTS.md`

## 已完成

新增 `scripts/youzi-update-appcast.py`、对应测试和
`docs/engineering/operations/youzi-app-updates.md`。CLI 强制显式外部私钥，
不访问 Keychain；比对公钥、应用版本/资源、完整 ZIP 文件内容/权限/链接，
使用官方工具在独立目录生成单条完整更新，再验证 feed/ZIP 签名并原子落盘。
原 ZIP 不重打包；只签版本固定的 Youzi release 地址。

可复用 `validate_feed(feed, archive, info)` 返回 archive signature，严格检查
单条目/单附件、签名 trailer 结构及长度、构建号/显示版本、精确 URL/大小。
该函数本身是结构检查；密码学验证由 `build_appcast` 中的官方
`sign_update --verify --ed-key-file` 完成。Atlas 将复用它增加 manifest
发布阻断，避免现有 Actions 在没有 appcast 的情况下继续发布。

真实测试发现官方 generate_appcast 首次解包会验证 Apple 代码签名，但
后续缓存路径可能不重复验证。因此本工具总是先执行独立
`codesign --verify --deep --strict`，不依赖生成器缓存行为。

## 验证

在本地 macOS、官方 Sparkle 2.9.5 上执行：

```bash
YOUZI_SPARKLE_BIN=/path/to/Sparkle/bin \
  python3 -m pytest --noconftest -c /dev/null -p no:cacheprovider \
  tests/test_youzi_update_appcast.py tests/test_youzi_update_key.py \
  tests/test_youzi_release_manifest.py -q
```

结果：43 项通过，无跳过。真实联测使用临时 RFC 8032 seed、ad-hoc 测试应用、官方 framework 和 ditto
归档，验证签名成功、feed/ZIP 篡改拒绝、旧 feed/模型 ZIP 隔离、归档字节不变。
不设置 `YOUZI_SPARKLE_BIN` 时真实联测会跳过，不能代替上述验收。

只读检查当前已安装 Youzi 应用的 11 个符号链接：均留在应用包内，无断链，
符合工具的归档一致性约束。未修改用户应用或生成生产密钥。

## 下一步与边界

1. Atlas 集成本分支的发布工具提交；不要重复集成已在主工作分支上的密钥工具。
2. Atlas 为 `youzi-release-manifest.py` 加缺失/不匹配 appcast 阻断并覆盖测试；
   操作文档已按这一集成约定描述当前 workflow 的失败行为。
3. Atlas 完成正式公钥配置、Swift 更新入口和真实临时应用下载/安装/重启验收。
4. 生产发布需要维护者明确授权。本分支没有 push、release、生产私钥生成、
   Keychain 操作或工作流修改。现有 hosted workflow 尚无私钥和签名步骤，
   不应绕过发布阻断。

未创建浏览器会话。此任务工作树尚未合并，保留给 Atlas 集成；确认合并、
干净且无人使用后按仓库约定移到系统废纸篓并清理 registration。
