import SwiftUI

struct SettingsPersonalizationPanel: View {
    @Environment(CustomInstructionsConfig.self) private var config
    @Environment(YouziI18nConfig.self) private var i18n

    var body: some View {
        @Bindable var settings = config
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            SectionHeader(t("个性化", "Personalization"),
                          subtitle: t("让柚子更符合你的习惯。称呼与回复偏好从下一次发送起生效，只保存在本机。", "Make Youzi feel familiar. Names and reply preferences apply from your next message and are stored locally."),
                          emphasis: .page)
            SettingsSection(t("称呼与身份", "Names & Identity")) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: RapidTheme.Space.lg) { identityFields }
                    VStack(alignment: .leading, spacing: RapidTheme.Space.md) { identityFields }
                }
            }
            SettingsSection(t("回复偏好", "Reply Preferences")) {
                Picker(t("回复风格", "Reply Style"), selection: $settings.replyStyle) {
                    Text(t("自然均衡", "Balanced")).tag(CustomInstructionsConfig.ReplyStyle.balanced)
                    Text(t("简洁直接", "Concise")).tag(CustomInstructionsConfig.ReplyStyle.concise)
                    Text(t("详细解释", "Detailed")).tag(CustomInstructionsConfig.ReplyStyle.detailed)
                    Text(t("轻松友好", "Friendly")).tag(CustomInstructionsConfig.ReplyStyle.friendly)
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Settings.Personalization.ReplyStyle")
                Text(t("这是默认偏好，你仍可以在对话中提出不同要求。", "A default preference; you can ask for a different style in a conversation."))
                    .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
            }
            InstructionEditorSection(
                t("自定义指令", "Custom Instructions"),
                subtitle: t("补充你的工作背景、回答习惯或约定。保留原有内容，最多 4,000 字。对话中的明确要求优先。", "Add work context or answer preferences. Existing instructions are preserved, up to 4,000 characters. Explicit conversation instructions take priority."),
                clearEnabled: CustomInstructionsConfig.normalized(config.global) != nil,
                onClear: { config.global = "" }
            ) {
                InstructionTextEditor(text: $settings.global,
                    placeholder: t("例如：默认用中文回答；代码示例标明文件名；不确定时请直接说明。", "For example: use plain language, label code examples with filenames, and say when uncertain."),
                    height: 136, accessibilityIdentifier: "Settings.Instructions.GlobalEditor")
            }
            SettingsSection(t("等待体验", "While Waiting")) {
                Toggle(isOn: $settings.showsWaitingHints) {
                    SettingsRowLabel(title: t("显示长等待提示", "Show Long-Wait Hints"),
                        description: t("等待模型输出超过 8 秒时显示。不影响推理速度，不会自动重试或重启服务。", "Show a hint after 8 seconds without an answer. Does not change speed, retry requests, or restart the service."))
                }
                .toggleStyle(TrailingSettingsToggleStyle())
                .accessibilityIdentifier("Settings.Personalization.WaitingHints")
                if config.showsWaitingHints {
                    TextField(t("留空使用默认提示", "Leave empty for the default hint"), text: $settings.waitingText)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(t("自定义等待提示", "Custom Waiting Hint"))
                        .accessibilityIdentifier("Settings.Personalization.WaitingText")
                    Text(t("默认：还在等待模型回复，你可以继续等待，或点击停止。最多 160 字，仅作为界面提示，不发给模型。", "Default: Still waiting for the model. You can keep waiting or click Stop. Up to 160 characters, shown only in the interface, never sent to the model."))
                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                }
            }
            EffectiveSystemPromptDisclosure(global: config.global, conversation: "",
                accessibilityIdentifier: "Settings.SystemPrompt.EffectivePreview")
        }
    }

    @ViewBuilder private var identityFields: some View {
        @Bindable var settings = config
        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
            Text(t("AI 对我的称呼", "What AI Calls Me")).font(RapidFont.bodyEmphasis)
            TextField(t("留空，不指定称呼", "Optional"), text: $settings.userAddress)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Settings.Personalization.UserAddress")
            Text(t("自然使用，不会每次回答都叫一遍。", "Used naturally, not in every answer."))
                .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
        }.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
            Text(t("AI 的名字", "AI's Name")).font(RapidFont.bodyEmphasis)
            TextField(t("柚子（默认）", "柚子 (default)"), text: $settings.assistantName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Settings.Personalization.AssistantName")
            Text(t("对话中的名字，不改变应用名称。", "A conversational name, not the app name."))
                .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
        }.frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    }

    private func t(_ zh: String, _ en: String) -> String { i18n.text(zh: zh, en: en) }
}
