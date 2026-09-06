import SwiftUI

struct YouziModelApprovalDialog: ViewModifier {
    let store: YouziModelApprovalStore?
    @Environment(YouziI18nConfig.self) private var i18n

    func body(content: Content) -> some View {
        let presentedRequest = store?.pending
        content.sheet(item: Binding(get: { presentedRequest }, set: { value in
            if value == nil, let request = presentedRequest { store?.resolve(id: request.id, allow: false) }
        })) { request in
            VStack(alignment: .leading, spacing: 16) {
                Text(i18n.text(zh: "允许启动本地模型？", en: "Start a local model?"))
                    .font(RapidFont.sectionTitle)
                Text(BrowseApprovalStore.displaySafe(request.alias)).font(RapidFont.bodyEmphasis)
                Text(BrowseApprovalStore.displaySafe(request.reason)).font(RapidFont.body)
                if let size = request.diskSize {
                    Text(i18n.text(zh: "模型文件：", en: "Model files: ") + size).font(RapidFont.secondary)
                }
                Text(i18n.text(
                    zh: "会占用额外内存。不会下载新模型或退出当前聊天服务；同类语音模型可能被替换。内存不足时会报告失败。",
                    en: "Uses additional memory. No downloads or chat-server restart. An existing model in the same audio lane may be replaced. Insufficient memory will be reported."
                )).font(RapidFont.secondary).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(i18n.text(zh: "不允许", en: "Don't allow")) { store?.resolve(id: request.id, allow: false) }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("YouziModelApprovalDialog.Button.484d198fd0")
                    Button(i18n.text(zh: "允许此次启动", en: "Allow this start")) { store?.resolve(id: request.id, allow: true) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("YouziModelApprovalDialog.Button.45e21313b6")
                }
            }.padding(24).frame(width: 440)
        }
    }
}
