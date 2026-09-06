import SwiftUI

/// Model-service credentials belong next to the API address, not tool settings.
struct SettingsEmbeddedAPISecurityPanel: View {
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @AppStorage(ModelServicePreference.anonymousInferenceKey) private var anonymousInference = false
    @State private var copied = false
    @State private var confirmRotation = false
    @State private var confirmAnonymous = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(i18n.text(zh: "API Key 验证", en: "Require API Key"), isOn: Binding(
                get: { !anonymousInference },
                set: { required in
                    if required { anonymousInference = false }
                    else { confirmAnonymous = true }
                }
            ))
            .accessibilityIdentifier("Settings.Models.Service.RequireAPIKey")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { keyLabel; Spacer(minLength: 8); keyActions }
                VStack(alignment: .leading, spacing: 8) { keyLabel; keyActions }
            }
            Text(i18n.text(zh: "Key 固定保存在钥匙串，不自动更新；可访问模型管理，请勿分享。", en: "Key stays in Keychain until replaced. It also grants model-management access; do not share it."))
                .font(RapidFont.caption).foregroundStyle(.secondary)
            if server.activeBearer != nil && anonymousInference != server.activeAnonymousInferenceAllowed {
                Text(i18n.text(zh: "鉴权更改待保存：点击右下角保存，立即应用到当前服务。", en: "Authentication change pending: click Save to apply to the running service."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
            if server.embeddedBearerRotationPending {
                Text(i18n.text(zh: "新 Key 已保存，重启服务后生效；复制按钮仍复制当前有效的 Key。", en: "New key saved for the next start. Copy still returns the currently active key."))
                    .font(RapidFont.caption)
                    .accessibilityIdentifier("Settings.Tools.EmbeddedAPI.RestartNotice")
            }
            if case .materialized(_, _, let issue) = server.embeddedBearerStatus, let issue {
                Text(issueText(issue)).font(RapidFont.caption).foregroundStyle(.red)
                    .accessibilityIdentifier("Settings.Tools.EmbeddedAPI.DegradedNotice")
            }
        }
        .alert(i18n.text(zh: "允许本机免密调用？", en: "Allow local requests without a key?"), isPresented: $confirmAnonymous) {
            Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) {}
            Button(i18n.text(zh: "允许", en: "Allow")) { anonymousInference = true }
        } message: {
            Text(i18n.text(zh: "本机其他程序将能够调用推理接口。模型管理仍需 Key，跨站网页和非本机访问不会放开。保存后立即生效。", en: "Other local programs can call inference endpoints. Model management still requires a key; cross-origin and remote requests remain protected. Applies on next service start."))
        }
        .alert(i18n.text(zh: "随机生成新的 API Key？", en: "Generate a new API Key?"), isPresented: $confirmRotation) {
            Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) {}
            Button(i18n.text(zh: "生成", en: "Generate")) {
                server.setEmbeddedBearerLifetime(.explicit)
                _ = server.rotateEmbeddedBearerNow()
            }
        } message: {
            Text(i18n.text(zh: "当前服务不受影响。下次启动服务后，外部客户端需换用新的 Key。", en: "The running service is unaffected. External clients need the new key after the next service start."))
        }
        .onChange(of: server.activeBearer) { _, _ in copied = false }
    }

    private var keyLabel: some View {
        Text(server.activeBearer == nil
             ? i18n.text(zh: "API Key · 服务未启动", en: "API Key · Service stopped")
             : "API Key  ••••••••")
            .font(RapidFont.body)
    }

    private var keyActions: some View {
        HStack(spacing: 8) {
            Button(i18n.text(zh: copied ? "已复制 ✓" : "复制 Key", en: copied ? "Copied ✓" : "Copy key")) {
                copied = ModelAPIKeyClipboard.shared.copy(server.activeBearer)
            }
            .disabled(server.activeBearer?.isEmpty != false)
            .accessibilityIdentifier("Settings.Models.Service.CopyKey")
            Button(i18n.text(zh: "随机生成", en: "Generate new")) { confirmRotation = true }
                .accessibilityIdentifier("Settings.Tools.EmbeddedAPI.RotateNow")
        }
    }

    private func issueText(_ issue: EmbeddedBearerStorageIssue) -> String {
        let zh: String
        switch issue {
        case .generationFailed: zh = "无法安全生成 Key，模型服务未启动。"
        case .missingSecret: zh = "未找到可用的已保存 Key，服务改用一次性 Key。"
        case .corruptedCredential: zh = "已保存凭据损坏，服务改用一次性 Key。"
        case .unavailableKeychain: zh = "系统钥匙串不可用，无法持久保存凭据。"
        case .writeFailed: zh = "新 Key 保存失败。当前服务的 Key 未变，请稍后重试。"
        case .deleteFailed: zh = "无法删除钥匙串中保存的 Key，请重试清理。"
        }
        return i18n.text(zh: zh, en: SettingsToolsPanel.embeddedBearerIssueCopy(issue))
    }
}
