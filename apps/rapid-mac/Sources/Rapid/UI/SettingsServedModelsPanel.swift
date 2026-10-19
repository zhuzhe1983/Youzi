import SwiftUI

/// A read-only view of /v1/models, not a second model pool.
struct SettingsServedModelsPanel: View {
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(SettingsRouter.self) private var router
    @State private var models: [ModelServiceCatalogClient.Model] = []
    @State private var checking = true
    @State private var failed = false

    var body: some View {
        SettingsSection(i18n.text(zh: "对外可用模型", en: "Available API models")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(i18n.text(zh: "此列表与 /v1/models 一致，随本地模型加载、卸载自动更新。远程替代不对外提供，无需另设模型。", en: "Matches /v1/models and updates as local models load or unload. Remote alternatives are not exposed; there is no separate model configuration."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
                if checking { ProgressView().controlSize(.small) }
                else if failed {
                    Text(i18n.text(zh: "暂时无法读取当前服务，将自动重试。", en: "Could not read the current service. Retrying automatically."))
                        .foregroundStyle(.secondary)
                } else if models.isEmpty {
                    Text(i18n.text(zh: "暂无已加载的本地模型。请先在“模型加载”中选择并加载。", en: "No local models are loaded. Select and load one in Model loading."))
                        .foregroundStyle(.secondary)
                }
                ForEach(models) { model in
                    HStack(alignment: .top) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(verbatim: model.id).font(RapidFont.secondary).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(i18n.text(zh: "已加载", en: "Loaded")).font(RapidFont.caption).foregroundStyle(.secondary)
                    }
                }
                Button(i18n.text(zh: "前往模型加载", en: "Open Model loading")) {
                    router.route(to: .modelLoading, open: {})
                }.accessibilityIdentifier("Settings.Models.Service.OpenLoading")
            }
            .accessibilityIdentifier("Settings.Models.Service.LoadedModels")
        }
        .task(id: server.state) {
            models = []; failed = false; checking = true
            guard case .ready = server.state, let bearer = server.activeBearer else { checking = false; return }
            let port = server.activePort
            while !Task.isCancelled {
                do {
                    let current = try await ModelServiceCatalogClient().models(port: port, bearer: bearer)
                    try Task.checkCancellation()
                    models = current; failed = false
                } catch {
                    guard !Task.isCancelled else { return }
                    models = []; failed = true
                }
                checking = false
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
