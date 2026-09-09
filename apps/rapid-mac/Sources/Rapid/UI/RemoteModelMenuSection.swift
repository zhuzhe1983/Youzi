import SwiftUI

/// Secondary choices only. Remote entries never acquire download/load/delete actions.
struct RemoteModelMenuSection: View {
    let slot: RemoteModelSlot
    let selection: String
    var entries: [ModelEntry]? = nil
    var automatic: () -> String?
    var select: (String) -> Void
    @Environment(YouziI18nConfig.self) private var i18n
    private var models: [ModelEntry] {
        entries ?? RemoteModelSettings.shared.entries(kind: slot.kind).filter {
            RemoteModelSettings.shared.document.model(alias: $0.alias)?.slot == slot
        }
    }
    var body: some View {
        if !models.isEmpty {
            Divider()
            Button(i18n.text(zh: "按当前优先级选择", en: "Choose by current priority")) {
                if let alias = automatic() { select(alias) }
            }.accessibilityIdentifier("Models.Priority.\(slot.rawValue)")
            Section(i18n.text(zh: "远程模型（可选）", en: "Remote models (optional)")) {
                ForEach(models) { entry in
                    Button { select(entry.alias) } label: {
                        Label(RemoteModelSettings.shared.title(entry.alias), systemImage: "network")
                    }
                    .accessibilityAddTraits(selection == entry.alias ? .isSelected : [])
                    .accessibilityIdentifier("Models.Remote.\(entry.alias)")
                }
            }
        }
    }
}
