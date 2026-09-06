import SwiftUI

/// Mounted only while an assistant row is waiting for output. Cancellation on
/// disappearance prevents a stale timer from appearing on a completed turn.
struct ChatWaitingHint: View {
    @Environment(CustomInstructionsConfig.self) private var config: CustomInstructionsConfig?
    @Environment(YouziI18nConfig.self) private var i18n: YouziI18nConfig?
    @State private var longWait = false

    var body: some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(t("正在处理…", "Processing…"))
                if longWait && (config?.showsWaitingHints ?? true) {
                    Text(Self.hint(custom: config?.waitingText ?? "", chinese: i18n?.isChinese ?? true))
                        .accessibilityIdentifier("Chat.LongWaitHint")
                }
            }.font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
        }
        .padding(.vertical, 2)
        .task {
            longWait = false
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !Task.isCancelled else { return }
            longWait = true
        }
    }

    nonisolated static func hint(custom: String, chinese: Bool) -> String {
        let text = CustomInstructionsConfig.singleLine(custom, limit: 160).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return chinese ? "还在等待模型回复，你可以继续等待，或点击停止。" : "Still waiting for the model. You can keep waiting or click Stop."
    }
    private func t(_ zh: String, _ en: String) -> String { i18n?.text(zh: zh, en: en) ?? zh }
}
