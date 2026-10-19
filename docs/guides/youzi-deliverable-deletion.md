# 成果文件删除

成果卡片的「…」菜单、右键菜单和成果预览均提供「删除…」。选中后先确认，再执行删除；取消不修改记录或文件。

- Youzi 管理的生成文件移到 macOS 废纸篓，可在 Finder 中恢复文件。恢复文件不会自动恢复已移除的成果卡片。
- 外部文件或工作空间文件只移除成果记录，不触碰原文件。
- 任务和聊天记录保留，聊天中的原成果卡片标注「成果已删除」。成果列表和项目成果列表过滤已归档的记录。
- 已丢失的文件仍可移除其成果记录。废纸篓不可用、权限或保存失败时显示错误，可重试，不退回永久删除。

实现先持久化不可用状态，再移动受管文件，成功后归档成果。文件移动之后最终保存失败也能安全重试。保留文件与成果 ID，确保任务/对话引用完整；不改数据格式版本。

验证：`RAPID_DESKTOP_NO_PORT_SWEEP=1 swift test --package-path apps/rapid-mac --filter 'YouziArtifactDeletionTests|YouziArtifactMediaTests|YouziLifecycleRepositoryTests|YouziManagedFileStoreTests|YouziProductModelTests|YouziChatArtifactTests'`。
