import SwiftUI

/// Row content shared by local and remote choices; checks indicate selection only.
struct YouziScenarioModelRow: View {
    let title: String
    var detail: String = ""
    var remoteStatus: YouziRemoteModelAvailability.Status? = nil
    var resident = false
    var selected = false
    var loading = false
    @Environment(YouziI18nConfig.self) private var i18n

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: remoteStatus == nil ? "desktopcomputer" : "network")
                .foregroundStyle(remoteStatus == nil && resident ? Color.green : RapidTheme.textSecondary)
                .frame(width: 18)
                .accessibilityLabel(remoteStatus == nil ? i18n.text(zh: "本地模型", en: "Local model") : i18n.text(zh: "远程模型", en: "Remote model"))
            Text(title).font(RapidFont.secondary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let remoteStatus {
                Text(statusLabel(remoteStatus)).font(RapidFont.caption)
                    .foregroundStyle(remoteStatus == .online ? Color.green : RapidTheme.textSecondary)
                    .fixedSize()
                    .help(i18n.text(zh: "在线表示近期已通过该服务的模型列表校验，不保证生成请求一定成功。未提供模型列表的服务暂不能验证。",
                                    en: "Online means this model was recently verified in the service's model list, not a guarantee of generation success. Services without model listing cannot be verified."))
            } else {
                Text(detail).font(RapidFont.caption)
                    .foregroundStyle(resident ? Color.green : RapidTheme.textSecondary).fixedSize()
            }
            ZStack {
                if loading { ProgressView().controlSize(.mini) }
                else if selected { Image(systemName: "checkmark").foregroundStyle(.green) }
            }.frame(width: 14)
        }
        .padding(8).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(selected ? i18n.text(zh: "当前选择", en: "Selected") : i18n.text(zh: "未选择", en: "Not selected"))
    }

    private func statusLabel(_ status: YouziRemoteModelAvailability.Status) -> String {
        switch status {
        case .online: i18n.text(zh: "远程在线", en: "Remote online")
        case .offline: i18n.text(zh: "远程离线", en: "Remote offline")
        case .checking: i18n.text(zh: "检测中", en: "Checking")
        case .unchecked: i18n.text(zh: "尚未验证", en: "Not verified")
        }
    }
}
