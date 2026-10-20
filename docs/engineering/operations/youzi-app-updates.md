# Youzi 应用内更新的签名与发布

Youzi 使用 Sparkle 下载完整 ZIP、验证签名、替换应用并重新启动。更新 feed
固定为
`https://github.com/zhuzhe1983/Youzi/releases/latest/download/appcast.xml`；
每个条目的 ZIP 地址固定到对应版本的 `youzi-vX.Y.Z` release，不能使用
`latest/download` 指向可变的 ZIP。

`scripts/youzi-update-appcast.py` 是发布前的必需步骤。它使用 Sparkle 官方
`generate_appcast` 和 `sign_update`，只接受显式提供的外部私钥文件。
缺少密钥、签名失败或包不一致时，必须停止发布；不能省略 appcast 后继续发布。

0.14.6 及更早的 Youzi 安装包没有内置此更新公钥，需手动安装一次包含新配置的版本；之后才可使用应用内升级。本次代码改动没有发布新版本，也没有修改已有 release 附件。

## 密钥与应用配置

私钥是 base64 编码的 32 字节 Ed25519 seed，放在仓库、应用包及发布目录之外，
由当前用户拥有，权限为 `0600`。其父目录建议设为 `0700`。保留安全备份，
不要写入 Git、应用资源、发布附件、日志或 Keychain。

已有正式密钥时直接复用。只有首次建立更新渠道时才生成新密钥；下面的命令
不会覆盖已有文件，stdout 只输出公钥：

```bash
swift scripts/youzi-update-key.swift generate \
  --private-key-file "$HOME/Library/Application Support/Youzi Release/signing/ed25519.seed"
```

查看已有密钥对应的公钥：

```bash
swift scripts/youzi-update-key.swift public-key \
  --private-key-file "$HOME/Library/Application Support/Youzi Release/signing/ed25519.seed"
```

发布应用的 `Contents/Info.plist` 必须包含与该密钥对应的 `SUPublicEDKey`、
上述 `SUFeedURL`，并将 `SURequireSignedFeed` 和
`SUVerifyUpdateBeforeExtraction` 均设为 `true`。不要在应用打包、代码签名后
再修改这些值。构建号 `CFBundleVersion` 必须是递增的正整数；
`CFBundleShortVersionString` 使用 `X.Y.Z`，并与内置 runtime 的 `VERSION`
一致。

Sparkle 2.9 起支持签名 feed；启用该功能也需要启用解包前验证。feed 或外部
release notes 签名后再修改，需要重新签名。本工具把更新说明嵌入 feed，减少
需要同时发布的文件。参见 [Sparkle 配置说明](https://sparkle-project.org/documentation/)
和 [发布说明](https://sparkle-project.org/documentation/publishing/)。

## 本地发布流程

1. 从目标发布提交构建完整应用，包含推理 runtime 和 Sparkle.framework。
   使用已配置的正式公钥，运行应用回归检查、资源检查和
   `codesign --verify --deep --strict`。先确认版本号和构建号均高于已发布版本。
2. 从这份最终应用制作 ZIP、DMG 和 sidecar；保留同一份 `.app` 用于后续比对。
   更新 ZIP 必须只有该应用，以及 `ditto` 生成的 AppleDouble 元数据。保留
   Unix 权限和符号链接，不要用普通文件复制方式重建 framework。
3. 运行以下签名命令，成功后才计算校验和、创建 draft 和执行安装验收。
   生产发布仍需明确的人类授权。

```bash
APP='apps/rapid-mac/build/Rapid-MLX Desktop.app'
OUT="$PWD/dist-youzi"
KEY="$HOME/Library/Application Support/Youzi Release/signing/ed25519.seed"
SPARKLE_BIN="$PWD/apps/rapid-mac/.build/artifacts/sparkle/Sparkle/bin"

mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" \
  "$OUT/Youzi-macos-arm64.zip"

python3 scripts/youzi-update-appcast.py \
  --app "$APP" \
  --archive "$OUT/Youzi-macos-arm64.zip" \
  --output-dir "$OUT" \
  --key-file "$KEY" \
  --sparkle-bin "$SPARKLE_BIN"
```

`--sparkle-bin` 必须指向官方 Sparkle 2.9 或更高版本的 `bin` 目录；SwiftPM
解包目录以本机构建结果为准。当前项目验证使用 2.9.5。工具不会重打包 ZIP，
也不会调用默认 Keychain 密钥。具体检查包括：

- 验证应用代码签名、Youzi bundle identifier、版本、runtime 版本和安全配置。
- 推导私钥对应的公钥，必须与应用内的 `SUPublicEDKey` 完全一致。
- 逐个比对 ZIP 与应用中的文件内容、Unix 权限、符号链接及所有资源，拒绝
  缺失文件、不同应用、额外模型文件、路径穿越、损坏 ZIP 和越出应用包的链接。
- 在独立临时目录中，只对指定 ZIP 生成一个完整更新条目，不读取输出目录里
  的旧 feed、旧 ZIP 或模型归档，也不生成 delta。
- 校验生成条目的构建号、显示版本、精确下载地址和文件长度，再用
  `sign_update --verify --ed-key-file` 分别验证 feed 与 ZIP。
- 确认原 ZIP 和临时 ZIP 的 SHA-256 均未变化，再原子替换输出 `appcast.xml`。
  失败时不写入新 feed；已有 appcast 可能属于旧版本，不能据此继续发布。

更新说明取自 Git 已跟踪的 `docs/release-notes/youzi-vX.Y.Z.md`，且只使用当前
版本。没有匹配文件时使用当前版本及其 release 页链接，不复用旧版本说明。
空的已跟踪说明文件会导致失败。

`scripts/youzi-release-manifest.py` 仍为现有 runtime/旧客户端渠道生成
`latest.json`。先按原流程制作同版本 DMG 和 sidecar，再完成上述 appcast
签名，最后运行 `python3 scripts/youzi-release-manifest.py "$OUT"` 并计算校验和。
对于启用签名 feed 的应用，manifest 生成会检查 appcast 必须存在，签名字段、
构建号、版本和 ZIP 信息须匹配；此结构检查不能代替签名工具的密码学验证。
appcast 不替代 `latest.json`，两个渠道必须来自同一次最终构建。

在创建 GitHub draft 之前，至少确认以下附件齐全：

```text
Youzi-macos-arm64.zip
Youzi-macos-arm64.dmg
rapid-mlx-sidecar.tar.gz
latest.json
appcast.xml
SHA256SUMS
```

在所有文件签名完成后重新生成 `SHA256SUMS`，包含 `appcast.xml`。上传之后
不要重新压缩 ZIP、编辑 XML 或替换同名附件。若必须修改，重新生成整套
签名和校验和，并重新验收；已经发布的版本优先通过新构建号的修复版本纠正。

## GitHub Actions 的当前边界

现有 `.github/workflows/youzi-package.yml` 负责构建、打包和可选 draft，
尚未配置更新私钥，也没有调用本签名工具。对于启用签名 feed 的新构建，
manifest 检查会因缺少有效 appcast 而失败，阻止继续上传或创建 draft；
这是预期的发布阻断。旧工作流留下的 artifact/draft 也不能直接提升为正式
release。维护者必须完成上述本地签名步骤，上传同一份 ZIP 和已验证的
`appcast.xml`，并完成安装验收。

若使用 Actions 产物，保留最终 ZIP 的原始字节，用 `ditto -x -k` 在独立目录
中提取应用作为 `--app`，再对原 ZIP 运行签名工具。只有已嵌入正确公钥和
签名 feed 配置的构建才能通过。不要在提取出的应用里临时补公钥；这会破坏
应用与 ZIP 的一致性和代码签名。

后续接入 CI 时，应由受保护的 release 环境注入私钥，临时写入仓库外
`0600` 文件，并显式传给 `--key-file`。签名步骤须位于校验和与上传之前，
缺少 secret 或签名失败必须阻止发布。私钥文件在作业结束时清理，禁止
`set -x`，禁止输出 secret。本次改动不修改工作流。

## 发布验收与故障处理

发布前用可丢弃的旧版本应用副本和测试 feed 验证“检查更新 → 下载 →
安装并重新启动”，确认新进程来自更新后的应用，版本、构建号和 runtime
版本正确，原有用户数据保留。测试密钥和测试 feed 只能用于临时应用，
不能替换正式公钥或正式 feed。仅验证 XML 或成功下载不等于安装验收。

发布后从公开 release 下载 `appcast.xml` 和对应 ZIP，核对 `SHA256SUMS`，
并再次用同一显式密钥文件验证两种签名。确认
`releases/latest/download/appcast.xml` 能访问该 feed，条目的 URL 指向
正确的 `youzi-vX.Y.Z` 附件，再从实际旧版本检查更新。GitHub 的 latest
release 必须保留有效 `appcast.xml`。

遇到签名错误、密钥不匹配、缺失资源或构建号未递增时停止发布。先查明
构建产物与密钥对应关系，不通过关闭签名验证、改用浏览器下载或重新生成
生产私钥来绕过错误。Sparkle 更新签名与 Apple Developer ID/notarization
是不同机制；目前 ad-hoc 分发的应用仍需按现有首次安装说明处理。

正式发布出现问题时，先保留现有附件和证据。优先发布更高构建号的修复版本，
不要把旧版本改成更大的构建号后覆盖原附件。撤回或调整生产 feed 的操作
由 Atlas 与维护者确认，使用原发布密钥签名，记录操作与恢复路径。

## 可复现的工具测试

```bash
YOUZI_SPARKLE_BIN="$PWD/apps/rapid-mac/.build/artifacts/sparkle/Sparkle/bin" \
  python3 -m pytest --noconftest -c /dev/null -p no:cacheprovider \
  tests/test_youzi_update_appcast.py tests/test_youzi_update_key.py \
  tests/test_youzi_release_manifest.py -q
```

无 `YOUZI_SPARKLE_BIN` 或非 macOS 环境会跳过真实 Sparkle 联测，不能把
这种结果当作发布签名验收。联测仅使用临时目录中的 RFC 8032 测试密钥、
ad-hoc 签名测试应用和官方 Sparkle.framework；它验证真实 feed/ZIP 签名，
也验证篡改会被拒绝，不发布附件、不写 Keychain、不修改用户应用。
