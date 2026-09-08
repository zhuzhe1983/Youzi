import AppKit
import SwiftUI

/// Model Files: folders and storage above a native, sortable table shared by
/// chat/audio/image/video. The table owns presentation filters; downloads,
/// co-loading and confirmed file deletion retain their existing service paths.
struct SettingsModelManagementPanel: View {
    @Environment(ServerManager.self) private var server
    @Environment(DownloadManager.self) private var downloads
    @Environment(YouziI18nConfig.self) private var i18n

    // Seeded from the process-wide cache rather than starting empty: an
    // empty start re-rendered the spinner on every visit regardless of
    // whether the data was already cached.
    @State private var catalog: [ModelEntry] = ModelCatalogCache.seed(generation: 0) ?? []
    @State private var loading: Bool = ModelCatalogCache.seed(generation: 0) == nil
    @State private var pendingDeletion: ModelEntry?
    @State private var lastError: String?
    @State private var lastFreed: String?
    @State private var modelsVolumeFreeBytes: Int64?

    @State private var loadingTableAliases: Set<String> = []
    /// Which file category is showing (Chat / Audio / Image / Video). Model
    /// Management manages every kind, but never mixes them in one list.
    @State private var capability: ModelKind = .chat

    /// Issue #503: the user's chosen models folder (absolute path), or
    /// ``nil`` for the default location. Mirrors
    /// ``ModelsFolderPreference`` so the row + buttons re-render the
    /// moment the user picks / resets a folder without waiting on a
    /// catalog reload.
    @State private var customFolderPath: String? = ModelsFolderPreference.storedPath()

    /// Individually selected checkpoints linked into Youzi's own Application
    /// Support directory. This is intentionally separate from the global
    /// models-folder preference: one link must never nominate its parent as a
    /// cache or discovery root.
    @State private var linkedModels: [ExternalModelRegistry.Record] =
        (try? ExternalModelRegistry.records()) ?? []

    /// Detected once. Drives the "Recommended for your N GB Mac" header
    /// and which RAM bucket's role picks surface at the top (issue #507).
    /// Cheap sysctl probe; constant for the panel's lifetime.
    @State private var hardware: MacHardware = .detect()

    /// User-pinned favorites (issue #507). Floated to the top of the
    /// "All models" table regardless of sort. Seeded from defaults;
    /// toggled in-row via the star.
    @State private var favorites: Set<String> = ModelFavorites.load()

    /// codex r1 P2 (#210): without this we'd ride the stale catalog
    /// snapshot after a background download finishes — the row
    /// flips from ``Downloading…`` straight back to ``Not cached``
    /// because ``ModelCacheActions.statusBadge`` falls through to
    /// the catalog's ``cached == false`` once the job exits
    /// ``.running``. Track each alias' last-observed job status
    /// here; when any moves to ``.completed`` we re-read the
    /// catalog so the row re-resolves to ``.cached`` + the disk
    /// footer aggregation pulls in the new bytes.
    @State private var lastObservedJobStatuses: [String: ObservedJobStatus] = [:]

    /// Coarse fingerprint of ``DownloadManager.Job.Status`` so the
    /// ``onChange`` diff against ``downloads.jobs`` doesn't churn
    /// on every tqdm tick (which only mutates
    /// ``job.progress.phase`` inside ``.running``). Coarsening to
    /// the discriminator alone lets the catalog refresh fire on
    /// running → completed / running → failed / running →
    /// cancelled transitions only.
    enum ObservedJobStatus: Equatable, Sendable {
        case running
        case completed
        case failed
        case cancelled

        init(_ status: DownloadManager.Job.Status) {
            switch status {
            case .running: self = .running
            case .completed: self = .completed
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            }
        }
    }


    /// The combined 模型 page supplies the page title.
    var showsPageHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            if showsPageHeader {
                header
            }
            modelsFolderSection
            linkedModelsSection
            storageOverviewSection
            capabilityTabs
            if loading && catalog.isEmpty {
                loadingState
            } else if catalog.isEmpty {
                emptyState
            } else {
                modelFilesTable
            }
            if let lastError {
                InlineNotice(
                    message: lastError,
                    tone: .error,
                    actionTitle: i18n.text(zh: "关闭", en: "Dismiss"),
                    actionIdentifier: "Settings.ModelManagement.DismissError",
                    action: { self.lastError = nil }
                )
            }
            if let lastFreed {
                InlineNotice(
                    message: lastFreed,
                    tone: .success,
                    actionTitle: i18n.text(zh: "关闭", en: "Dismiss"),
                    actionIdentifier: "Settings.ModelManagement.DismissSuccess",
                    action: { self.lastFreed = nil }
                )
            }
        }
        // Loading, empty, and catalog branches are deliberately exclusive.
        // Animating this container retains both conditional trees during the
        // transition, which can overlay the spinner on stale model rows.
        .task {
            refreshLinkedModels()
            await refreshCatalog()
            refreshStorageCapacity()
        }
        // codex r1 P2 / codex r2 P2 fix: catch the running → terminal
        // transition without relying on SwiftUI's observation graph,
        // which can't see ``job.status`` mutate on the existing
        // ``Job`` reference type (``DownloadManager.handleExit``
        // doesn't reassign the dict entry). Without this watcher a
        // finished pull would stay on ``Downloading…`` until the
        // user switched tabs and back.
        //
        // The task is alive for the panel's lifetime; the inner
        // loop only spins while at least one job is ``.running``
        // (cheap 500 ms cadence — same as a tqdm tick — so a
        // terminal flip lands inside half a second). When no
        // running jobs remain the loop awaits a longer beat so the
        // idle Settings tab does no work. Tests pin the pure
        // transition predicate in ``shouldRefreshCatalog``.
        .task {
            await jobReconciliationLoop()
        }
        // ``confirmationDialog`` over ``alert`` so the cancel-role
        // button is Return-bound — same reasoning as the picker's
        // dialog in v0.6 P1, and we route the title/message
        // through ``ModelCacheActions.deletionConfirmation`` so
        // the wording matches.
        .confirmationDialog(
            i18n.text(zh: "删除模型文件？", en: "Delete model files?"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button(i18n.text(zh: "删除文件", en: "Delete files"), role: .destructive) {
                Task { await deleteAlias(entry) }
                pendingDeletion = nil
            }
            .accessibilityIdentifier("Settings.ModelManagement.ConfirmDelete")
            Button(i18n.text(zh: "保留", en: "Keep files"), role: .cancel) { pendingDeletion = nil }
                .accessibilityIdentifier("Settings.ModelManagement.KeepOnDisk")
        } message: { entry in
            Text(i18n.text(zh: "将删除 \(entry.alias) 的本地文件，需要时可重新下载。不会删除任务和对话。", en: "Remove local files for \(entry.alias). You can download them again. Tasks and conversations are not deleted."))
        }
    }

    // MARK: - Native sortable model-file table

    private var tableRows: [YouziModelTableData.Row] {
        let recommendations = capability == .chat ? Array(recommendedPicks.prefix(2)) : []
        return catalog.filter { $0.supports(capability) }.map { entry in
            YouziModelTableData.Row(
                entry: entry,
                badge: ModelCacheActions.statusBadge(for: entry, downloadJob: downloads.jobs[entry.alias], servingAlias: server.servingAlias),
                loaded: YouziScenarioModels.isReady(entry, in: server.residency) || server.servingAlias == entry.alias,
                loading: loadingTableAliases.contains(entry.alias) || server.residentLoadsInFlight[entry.alias, default: 0] > 0,
                recommendationRank: recommendations.firstIndex { $0.pick.alias == entry.alias },
                favorite: favorites.contains(entry.alias),
                scores: capability == .chat ? BenchScoresCatalog.lookup(alias: entry.alias) : nil
            )
        }
    }

    private var modelFilesTable: some View {
        YouziModelTableView(rows: tableRows, hardwareDescription: hardware.shortDescription,
            download: { entry in
                guard tableRows.first(where: { $0.id == entry.alias })?.canDownload == true else { return }
                downloads.dismissJob(alias: entry.alias)
                _ = downloads.startDownload(alias: entry.alias, hfPath: entry.hfRepo)
            },
            cancel: { downloads.cancelDownload(alias: $0.alias) },
            load: { entry in Task { await loadTableModel(entry) } },
            delete: { entry in
                guard tableRows.first(where: { $0.id == entry.alias })?.canDelete == true else { return }
                pendingDeletion = entry
            },
            favorite: { toggleFavorite($0.alias) })
        .id(capability)
    }

    private func loadTableModel(_ entry: ModelEntry) async {
        guard tableRows.first(where: { $0.id == entry.alias })?.canLoad == true else { return }
        loadingTableAliases.insert(entry.alias)
        defer { loadingTableAliases.remove(entry.alias) }
        lastError = nil
        let success: Bool
        if server.servingAlias != nil { success = await server.loadStartupModel(entry) }
        else if entry.kind == .chat { success = await server.ensureServing(alias: entry.alias, hfPath: entry.hfRepo) }
        else {
            lastError = i18n.text(zh: "请先启动聊天服务，再加载图片、语音或视频模型。", en: "Start the chat service before loading an image, audio or video model.")
            return
        }
        if !success {
            lastError = server.residentLoadFailures[entry.alias]?.message
                ?? i18n.text(zh: "模型未能加载，请检查模型设置或服务日志。", en: "Model could not load. Check model settings or service logs.")
        }
    }

    // MARK: - Header / controls

    @ViewBuilder
    private var header: some View {
        SectionHeader(
            i18n.text(zh: "模型", en: "Model Management"),
            subtitle: i18n.text(
                zh: "管理本地磁盘上的模型缓存。在后台下载所需模型，删除不需要的模型以释放空间。",
                en: "Manage the on-disk model cache. Download what you need in the background; delete what you don't to reclaim space."
            ),
            emphasis: .page
        )
    }

    // MARK: - Models folder (issue #503)

    /// Where Rapid keeps the models it downloads. Defaults to an
    /// internal location; the user can point it at any folder — e.g. a
    /// large shared model collection on an external drive — so downloads
    /// stop clogging the internal disk. The engine, the app's disk
    /// scanning, and deletion all follow this same folder
    /// (``ModelsFolderPreference``), so the numbers stay honest.
    @ViewBuilder
    private var modelsFolderSection: some View {
        let unavailable = ModelsFolderPreference.customFolderUnavailable()
        SettingsSection("Models folder") {
            VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
                    Image(systemName: customFolderPath == nil ? "internaldrive" : "externaldrive")
                        .foregroundStyle(RapidTheme.utilityActionLabel)
                        .frame(width: RapidTheme.Layout.iconSlot)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                        Text(customFolderPath == nil ? "Default location" : "Custom folder")
                            .font(RapidFont.bodyEmphasis)
                            .foregroundStyle(RapidTheme.textPrimary)
                        Text(effectiveFolderDisplayPath)
                            .font(RapidFont.code)
                            .foregroundStyle(RapidTheme.textSecondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("Settings.ModelManagement.FolderPath")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if unavailable {
                    InlineNotice(
                        message: "Your chosen models folder isn't available right now — the drive may be unplugged. Youzi is using its default location until it's back.",
                        tone: .warning
                    )
                    .accessibilityIdentifier("Settings.ModelManagement.FolderUnavailable")
                }

                HStack(spacing: RapidTheme.Space.sm) {
                    Button(i18n.text(zh: "选择…", en: "Choose…")) { chooseModelsFolder() }
                        .buttonStyle(.rapidSecondaryCompact)
                        .accessibilityIdentifier("Settings.ModelManagement.ChooseFolder")
                    if customFolderPath != nil {
                        Button(i18n.text(zh: "恢复默认", en: "Use default")) { resetModelsFolder() }
                            .buttonStyle(.rapidTertiary)
                            .accessibilityIdentifier("Settings.ModelManagement.UseDefaultFolder")
                    }
                    Spacer(minLength: 0)
                }

                Text("Point Youzi at a folder where it already keeps downloaded models — for example on an external drive. New models download here; ones you already have stay where they are. Models downloaded by other apps in other formats won't appear here. New location takes effect the next time a model loads or downloads.")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Individually linked models

    @ViewBuilder
    private var linkedModelsSection: some View {
        SettingsSection("Linked models") {
            VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
                    Image(systemName: "link")
                        .foregroundStyle(RapidTheme.utilityActionLabel)
                        .frame(width: RapidTheme.Layout.iconSlot)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                        Text("Reuse one local MLX model")
                            .font(RapidFont.bodyEmphasis)
                            .foregroundStyle(RapidTheme.textPrimary)
                        Text("Choose a directly loadable model folder. Youzi links it in place without copying its weights or scanning neighboring models.")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(i18n.text(zh: "链接模型…", en: "Link model…")) { chooseModelToLink() }
                    .buttonStyle(.rapidSecondaryCompact)
                    .accessibilityIdentifier("Settings.ModelManagement.LinkModel")

                ForEach(linkedModels) { record in
                    SettingsRowDivider()
                    HStack(spacing: RapidTheme.Space.sm) {
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                            Text(record.alias)
                                .font(RapidFont.code)
                                .foregroundStyle(RapidTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(record.isAvailable ? "Available to Youzi" : "Source unavailable")
                                .font(RapidFont.caption)
                                .foregroundStyle(
                                    record.isAvailable
                                        ? RapidTheme.textSecondary
                                        : RapidTheme.statusWarning
                                )
                        }
                        Spacer(minLength: RapidTheme.Space.sm)
                        Button(i18n.text(zh: "取消链接", en: "Forget")) { forgetLinkedModel(record) }
                            .buttonStyle(.rapidTertiary)
                            .help(i18n.text(zh: "仅移除柚子的链接关系。原始模型及其所有权重文件均保持不变。", en: "Remove only Youzi's link. The original model and all of its weights stay untouched."))
                            .accessibilityLabel("Forget linked model \(record.alias)")
                            .accessibilityHint(i18n.text(zh: "仅移除柚子的链接关系并保留所有源文件。", en: "Removes only Youzi's link and keeps every source file."))
                            .accessibilityIdentifier(
                                "Settings.ModelManagement.ForgetLinkedModel.\(record.alias)"
                            )
                    }
                }

                Text("Forgetting a linked model removes only Youzi's link. The original folder and every source weight remain untouched.")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Preferences

    /// Model-behaviour toggles, including the two that used to live in a separate
    /// "Models" tab. Folded in here — the surface that already owns
    /// everything about your models — as one labelled card so the app
    /// has a single place to manage models rather than two competing
    /// ones. Styled to match ``modelsFolderSection`` above: a secondary
    /// section label over a hairline card, with dividers keeping the controls
    /// distinct without creating several floating boxes.
    /// The path shown in the folder row. When the user picked a custom
    /// folder we show exactly what they picked (even while unavailable,
    /// so the warning has context); otherwise we resolve + show the
    /// default location so "Default location" isn't an opaque label.
    private var effectiveFolderDisplayPath: String {
        if let custom = customFolderPath { return custom }
        let resolved = BundledModel.userHFCacheURL(
            environment: ProcessInfo.processInfo.environment
        )
        return resolved?.path ?? "~/.cache/huggingface/hub"
    }

    private var effectiveModelsFolderURL: URL? {
        ModelsFolderPreference.validatedOverrideURL()
            ?? BundledModel.userHFCacheURL(environment: ProcessInfo.processInfo.environment)
    }

    private func refreshStorageCapacity() {
        modelsVolumeFreeBytes = effectiveModelsFolderURL.flatMap {
            DiskSpaceProbe.freeBytes(forPath: $0.path)
        }
    }

    /// Always-visible cache overview. Unlike the old footer this spans Chat,
    /// Image, and Audio, and it excludes read-only entries owned by another
    /// runtime because this panel cannot reclaim those bytes.
    @ViewBuilder
    private var storageOverviewSection: some View {
        let managed = catalog.filter { !$0.isExternal }
        let usage = ModelCacheActions.aggregateOnDiskBytes(managed)
        let largest = ModelCacheActions.largestManagedEntry(managed)
        // Upstream (#1822) added this card in the pre-migration idiom —
        // `.callout` type, the legacy 12pt `cardRadius`, a local 12pt
        // inset. Same content and the same identifiers, moved onto the
        // shared section so it does not ship as the one un-migrated card
        // in the window.
        SettingsSection("Disk overview") {
            HStack(spacing: RapidTheme.Space.md) {
                Label("Models", systemImage: "internaldrive")
                    .font(RapidFont.bodyEmphasis)
                    .foregroundStyle(RapidTheme.textPrimary)
                Spacer(minLength: RapidTheme.Space.sm)
                Text(ModelCacheActions.storageSummary(
                    usage: usage,
                    freeBytes: modelsVolumeFreeBytes
                ))
                .font(RapidFont.metric)
                .foregroundStyle(RapidTheme.textSecondary)
                .accessibilityIdentifier("Settings.ModelManagement.StorageSummary")
            }
            if let largest {
                SettingsRowDivider()
                HStack(spacing: RapidTheme.Space.sm) {
                    Text("Largest")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                    Text(largest.alias)
                        .font(RapidFont.bodyEmphasis)
                        .foregroundStyle(RapidTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: RapidTheme.Space.sm)
                    Text(largest.sizeOnDisk ?? "")
                        .font(RapidFont.metric)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("Settings.ModelManagement.LargestModel")
            }
        }
    }

    /// Present a folder picker and persist the choice. Directories only;
    /// the app is not sandboxed so no security-scoped bookmark is
    /// needed to read/write the picked folder (including an external
    /// volume). Re-reads the catalog so the cached/size badges reflect
    /// what's in the newly chosen folder.
    private func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a models folder"
        panel.message = "Pick the folder where Youzi should keep downloaded models."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let current = customFolderPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ModelsFolderPreference.setStoredPath(url.path)
        customFolderPath = ModelsFolderPreference.storedPath()
        refreshStorageCapacity()
        Task { await refreshCatalog() }
    }

    /// Clear the custom folder and fall back to the default location.
    private func resetModelsFolder() {
        ModelsFolderPreference.setStoredPath(nil)
        customFolderPath = nil
        refreshStorageCapacity()
        Task { await refreshCatalog() }
    }

    private func chooseModelToLink() {
        let panel = NSOpenPanel()
        panel.title = "Link a local MLX model"
        panel.message = "Choose one model folder containing config.json and MLX safetensors weights."
        panel.prompt = "Link Model"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let linksDirectory = ExternalModelRegistry.linksDirectory()
        Task {
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try ExternalModelLinker.linkModel(at: source, into: linksDirectory)
                }.value
                let alias: String
                switch outcome {
                case .linked(let link), .alreadyLinked(let link): alias = link.lastPathComponent
                }
                refreshLinkedModels()
                downloads.markCacheChanged()
                await refreshCatalog()
                lastError = nil
                lastFreed = "Linked \(alias). Youzi will reuse the original weights in place."
            } catch {
                lastFreed = nil
                lastError = error.localizedDescription
            }
        }
    }

    private func forgetLinkedModel(_ record: ExternalModelRegistry.Record) {
        Task {
            lastError = nil
            lastFreed = nil
            if server.servingAlias == record.alias {
                await server.stop()
                guard server.servingAlias != record.alias else {
                    lastError = "Couldn't stop \(record.alias), so its link was kept."
                    return
                }
            }
            do {
                try ExternalModelLinker.removeManagedLink(
                    at: record.linkURL,
                    from: ExternalModelRegistry.linksDirectory()
                )
                refreshLinkedModels()
                downloads.markCacheChanged()
                await refreshCatalog()
                lastFreed = "Forgot \(record.alias). Only Youzi's link was removed; the original model is untouched."
            } catch {
                lastError = error.localizedDescription
                refreshLinkedModels()
            }
        }
    }

    private func refreshLinkedModels() {
        linkedModels = (try? ExternalModelRegistry.records()) ?? []
    }

    /// Stable file categories, including Video even before its first download.
    private var capabilityTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            RapidSegmentedControl(
                selection: $capability,
                options: ModelFileCategory.kinds.map {
                    .init(value: $0,
                          title: ModelFileCategory.title($0, isChinese: i18n.isChinese),
                          identifier: "Settings.ModelManagement.Kind.\($0.rawValue)")
                },
                accessibilityLabel: i18n.text(zh: "模型类型", en: "Model type")
            )
        }
        .accessibilityIdentifier("Settings.ModelManagement.CapabilityTabs")
    }

    private var recommendedPicks: [(pick: RAMBucketedDefault.Pick, isPrimary: Bool)] {
        RAMBucketedDefault.catalogPicks(from: hardware.recommendedPicks, catalog: catalog)
            .map { ($0.pick, $0.isPrimary) }
    }

    private var availableKinds: [ModelKind] { ModelFileCategory.kinds }

    private func toggleFavorite(_ alias: String) {
        _ = ModelFavorites.toggle(alias)
        favorites = ModelFavorites.load()
    }

    // Compatibility helpers for existing model-size and recommendation fixtures.
    static func pickStatsLine(_ pick: RAMBucketedDefault.Pick) -> String {
        var parts = [String(format: "%.1f GB", pick.footprintGB)]
        if let caveat = pick.caveat {
            if let tps = pick.tokensPerSec {
                parts.append("~\(Int(tps.rounded())) tok/s")
            }
            parts.append(caveat)
        } else {
            parts.append("\(pick.capabilityPct)% capability")
            if let tps = pick.tokensPerSec {
                parts.append("~\(Int(tps.rounded())) tok/s")
            }
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func downloadSizeLabel(_ alias: String) -> String? {
        let fp = ModelSizing.estimate(alias: alias)
        guard fp.weightsGB > 0 else { return nil }
        return String(format: "%.1f GB", fp.weightsGB)
    }

    nonisolated static func onDiskSizeLabel(_ entry: ModelEntry) -> String? {
        guard let raw = entry.sizeOnDisk?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    // MARK: - States

    @ViewBuilder
    private var loadingState: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            ProgressView().controlSize(.small)
            Text(i18n.text(zh: "正在读取模型列表…", en: "Loading model catalog…"))
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .padding(.vertical, RapidTheme.Space.md)
    }

    @ViewBuilder
    private var emptyState: some View {
        Text(i18n.text(zh: "模型列表读取失败，请重新打开设置后重试。", en: "Couldn't load the model list. Reopen settings to retry."))
            .font(RapidFont.body)
            .foregroundStyle(RapidTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, RapidTheme.Space.md)
    }

    // NOTE: local ``errorBanner(_:)`` and ``freedBanner(_:)`` builders
    // lived here. Each drew its own rounded rectangle out of
    // `Color.red.opacity(0.08)` / `RapidTheme.green.opacity(0.08)` at a
    // local 8pt radius, with its own Dismiss button — two more banner
    // styles on a window that already had three. Both call sites now use
    // ``InlineNotice`` with the `.error` / `.success` tones, which own
    // the same job for every surface in the app.

    // MARK: - Job reconciliation

    /// Coarse fingerprint of every job's status. ``onChange`` /
    /// ``task(id:)`` only fires when this changes — running →
    /// completed, running → failed, running → cancelled, or new
    /// jobs appearing / dropping. tqdm phase updates inside
    /// ``.running`` are intentionally ignored so we don't refresh
    /// the catalog 30 times a second mid-pull.
    ///
    /// Computed property (not @State) so it always reflects the
    /// live ``downloads.jobs`` snapshot; the @State
    /// ``lastObservedJobStatuses`` is the previous-frame copy that
    /// ``reconcileJobs`` diffs against to detect transitions.
    private var jobStatusFingerprint: [String: ObservedJobStatus] {
        var out: [String: ObservedJobStatus] = [:]
        out.reserveCapacity(downloads.jobs.count)
        for (alias, job) in downloads.jobs {
            out[alias] = ObservedJobStatus(job.status)
        }
        return out
    }

    /// Persistent reconciliation loop. Spins at 500 ms while any
    /// job is running, settles to 5 s when idle. Re-reads the
    /// catalog whenever a running → terminal transition is
    /// detected so the row flips from ``Downloading…`` to ``On
    /// disk`` / ``Failed`` / ``Not cached`` at the same cadence
    /// the user sees on the picker's download strip.
    ///
    /// The loop honours ``Task.isCancelled`` (the panel's
    /// ``.task`` is cancelled when the Settings view is dismissed
    /// or rebuilt) so this never out-lives the surface.
    private func jobReconciliationLoop() async {
        while !Task.isCancelled {
            let current = jobStatusFingerprint
            let previous = lastObservedJobStatuses
            let shouldRefresh = Self.shouldRefreshCatalog(
                previous: previous,
                current: current
            )
            lastObservedJobStatuses = current
            if shouldRefresh {
                await refreshCatalog()
            }
            // Hot poll while a pull is mid-flight; settle to a
            // light beat when no running jobs remain so the
            // idle Settings tab isn't waking on a sub-second
            // tick forever.
            let anyRunning = current.values.contains(.running)
            let interval: UInt64 = anyRunning ? 500_000_000 : 5_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    /// Pure predicate driving the ``reconcileJobs`` decision —
    /// exposed ``static`` so a unit test can pin every transition
    /// branch without standing up a SwiftUI host. The catalog
    /// needs a re-read whenever any alias' status transitioned
    /// FROM ``.running`` to a terminal state (``.completed`` is
    /// the on-disk flip; ``.failed`` / ``.cancelled`` are the
    /// give-up flips that also need the row to re-resolve so the
    /// action button settles into Retry / Download).
    static func shouldRefreshCatalog(
        previous: [String: ObservedJobStatus],
        current: [String: ObservedJobStatus]
    ) -> Bool {
        for (alias, newStatus) in current {
            let oldStatus = previous[alias]
            if oldStatus == .running && newStatus != .running {
                return true
            }
        }
        return false
    }

    // MARK: - Actions

    /// Load an atomic product snapshot only from a stable cache epoch.
    /// Downloads can finish while the CLI probes are suspended; retrying here
    /// prevents that older result from landing after the completion-triggered
    /// refresh and turning an on-disk row back into Download.
    @MainActor
    static func stableAtomicCatalogSnapshot(
        currentGeneration: @escaping @MainActor () -> UInt,
        loader: @escaping @MainActor () async -> [ModelEntry]?
    ) async -> [ModelEntry]? {
        while !Task.isCancelled {
            let generation = currentGeneration()
            let entries = await loader()
            guard !Task.isCancelled else { return nil }
            if generation == currentGeneration() { return entries }
        }
        return nil
    }

    private func refreshCatalog() async {
        guard let binary = server.binaryPath else {
            catalog = []
            loading = false
            return
        }
        // One atomic snapshot drives every capability tab. This avoids four
        // independent `models --json` calls and prevents tab-to-tab drift if a
        // sidecar or catalog changes during refresh. Older sidecars fall
        // through to the established per-surface compatibility loaders.
        if let atomic = await Self.stableAtomicCatalogSnapshot(
            currentGeneration: { downloads.cacheGeneration },
            loader: { await ModelCatalog.productEntries(binary: binary) }
        ) {
            catalog = atomic
            reconcileCapability()
            loading = false
            return
        }
        guard !Task.isCancelled else { return }
        let generation = downloads.cacheGeneration
        // Show a cached snapshot straight away and skip the spinner entirely —
        // flashing "loading" over data we already have makes every visit to
        // this panel feel like a cold start.
        if let hit = await ModelCatalogCache.shared.cached(
            binary: binary, generation: generation
        ) {
            async let image = ModelCatalog.imageEntries(binary: binary)
            async let audio = ModelCatalog.audioEntries(binary: binary)
            async let video = ModelCatalog.videoEntries(binary: binary)
            catalog = hit + (await image) + (await audio) + (await video)
            reconcileCapability()
            loading = false
            return
        }
        loading = true
        defer { loading = false }
        // Chat catalog + image-gen aliases, managed side by side. The image
        // rows carry ``kind == .image`` so the capability tabs keep them out of
        // the chat list (and vice-versa).
        let chat = await ModelCatalogCache.shared.entries(
            binary: binary, generation: generation
        )
        async let image = ModelCatalog.imageEntries(binary: binary)
        async let audio = ModelCatalog.audioEntries(binary: binary)
        async let video = ModelCatalog.videoEntries(binary: binary)
        catalog = chat + (await image) + (await audio) + (await video)
        reconcileCapability()
    }

    /// All four file categories remain available, including empty catalogs.
    private func reconcileCapability() {
        let kinds = availableKinds
        if !kinds.isEmpty, !kinds.contains(capability) {
            capability = kinds.first ?? .chat
        }
    }

    private func deleteAlias(_ entry: ModelEntry) async {
        lastError = nil
        lastFreed = nil
        guard !entry.isExternal, !loadingTableAliases.contains(entry.alias),
              server.residentLoadsInFlight[entry.alias, default: 0] == 0,
              server.servingAlias != entry.alias,
              !server.isModelResident(entry.alias),
              !(entry.hfRepo.map { server.isModelResident($0) } ?? false),
              !YouziScenarioModels.isReady(entry, in: server.residency) else {
            lastError = i18n.text(zh: "模型仍在使用中或属于外部文件，请先停止模型；外部文件请到原目录管理。", en: "This model is loaded/loading or externally managed. Stop it first; manage external files in their original folder.")
            return
        }
        let outcome = await ModelCacheActions.runDeletion(
            for: entry,
            binaryPath: server.binaryPath
        )
        switch outcome {
        case .success(let message, _):
            lastFreed = message
            // Other surfaces (picker dropdown, upgrade banner) hold
            // their own catalog snapshots; without this they keep
            // showing the deleted model as downloaded.
            downloads.markCacheChanged()
            await refreshCatalog()
        case .failure(let message):
            lastError = message
        }
    }
}

/// The heading above the models table: the subset on screen and how many
/// rows that is.
///
/// Its own view so the dev snapshot harness can render every filter state
/// side by side without re-implementing markup the panel ships — the
/// heading is the thing this pass changed, so it has to be reviewable in
/// all four of its states, not just the one a running panel happens to be
/// in.
struct ModelsTableHeading: View {
    let heading: ModelCacheActions.ListHeading

    var body: some View {
        HStack(spacing: RapidTheme.Space.xs) {
            Text(heading.title).font(RapidFont.groupLabel)
            Text("· \(heading.countText)")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textTertiary)
                .accessibilityIdentifier("Settings.ModelManagement.VisibleCount")
        }
        .foregroundStyle(RapidTheme.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(heading.accessibilityLabel)
    }
}

/// Fixed geometry of a Recommended card, lifted out of the view body so
/// the widths that decide whether a label renders in full are values a
/// test can measure instead of literals buried in a modifier chain.
///
/// The card clipped its primary call to action to "Dow…" because the
/// trailing slot was pinned to a hard 92pt that its own contents did not
/// fit inside. Deriving the floor from the labels — rather than picking
/// another literal and hoping — means adding a longer label, or bumping
/// the control size, moves the column with it.
enum RecommendedCardLayout {
    /// Leading marker column ("Best pick" / "Faster").
    static let markerColumnWidth: CGFloat = 74

    /// Horizontal chrome around a ``controlSize(.small)`` push-button's
    /// title: the bezel plus its internal padding. Deliberately generous
    /// — an over-estimate only widens a right-aligned column by a couple
    /// of points, while an under-estimate is the ellipsis we are fixing.
    static let smallButtonChrome: CGFloat = 26

    /// Horizontal chrome around a status pill's text — 8pt of capsule
    /// padding on each side (see ``SettingsModelManagementPanel.pill``).
    static let pillChrome: CGFloat = 16

    /// Every button label the card's trailing slot can render. "Delete"
    /// is included because ``actionButton`` still carries that branch,
    /// even though the cached card currently resolves to a pill.
    static let actionButtonTitles = ["Download", "Delete", "Cancel", "Retry"]

    /// Every status pill the same slot can render.
    static let actionPillTitles = ["On disk", "In use", "Serving", "External"]

    /// Intrinsic width of a small push-button with this title.
    static func buttonWidth(title: String) -> CGFloat {
        textWidth(title, font: .systemFont(ofSize: NSFont.smallSystemFontSize))
            + smallButtonChrome
    }

    /// Intrinsic width of a status pill with this text.
    static func pillWidth(text: String) -> CGFloat {
        textWidth(text, font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium))
            + pillChrome
    }

    /// Floor for the card's trailing slot: the widest thing it renders.
    /// The slot is free to grow past this (its content is `fixedSize`d);
    /// the floor exists so the stacked cards' buttons line up.
    static let actionColumnWidth: CGFloat = {
        let widest = actionButtonTitles.map(buttonWidth(title:))
            + actionPillTitles.map(pillWidth(text:))
        return (widest.max() ?? 92).rounded(.up)
    }()

    /// Width of a `.caption` run — the font the removed size caption used,
    /// kept so a test can show why it could not share the slot.
    static func captionWidth(_ text: String) -> CGFloat {
        textWidth(text, font: .systemFont(ofSize: 10))
    }

    /// Width of a `.caption.weight(.medium)` run — the table's "Serving"
    /// label.
    static func captionMediumWidth(_ text: String) -> CGFloat {
        textWidth(text, font: .systemFont(ofSize: 10, weight: .medium))
    }

    fileprivate static func textWidth(_ string: String, font: NSFont) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: font]).width
    }
}

/// Geometry of the "All models" table's trailing Size column.
///
/// The column is a fixed width shared by the header and every row —
/// variable widths would put each row's meters at a different x and make
/// the table ragged — so the width has to be chosen against the widest
/// cell rather than the narrowest.
///
/// It was 84pt, sized when a cached cell held two glyphs and nothing
/// between them. Serving rows now carry measured size, status, and a delete
/// control, so the column is wide enough for all three without truncation.
enum ModelTableLayout {
    /// Shared width of the Size column.
    static let sizeColumnWidth: CGFloat = 124

    /// Shared width of the Quality·Speed meters column.
    ///
    /// Was a bare `158` repeated in the row and again in the column
    /// header — two literals that had to agree for the table not to go
    /// ragged, with nothing enforcing it.
    static let metersColumnWidth: CGFloat = 158

    /// Leading chrome in a chat row before the model name: the favourite
    /// star, the brand icon, and the three gaps between the four columns.
    static let rowLeadingChromeWidth: CGFloat = 15 + 30 + RapidTheme.Space.sm * 3

    /// Everything a chat row commits to before the flexible model-name
    /// column gets a single point.
    ///
    /// Pure so ``SettingsResponsiveLayoutTests`` can assert the row still
    /// leaves a readable name at every supported window size, instead of
    /// that assertion living only in a screenshot somebody has to
    /// remember to take.
    static func committedRowWidth(showsMeters: Bool) -> CGFloat {
        rowLeadingChromeWidth
            + (showsMeters ? metersColumnWidth + RapidTheme.Space.sm : 0)
            + sizeColumnWidth
            // the grouped card's own horizontal inset, both edges
            + RapidTheme.Space.lg * 2
    }

    /// The narrowest model name we are willing to render before calling
    /// the layout broken. Roughly 14 characters at 13pt — enough for
    /// `qwen3.5-9b-4bit` to read with a middle truncation.
    static let minimumNameWidth: CGFloat = 120

    /// Spacing between the glyph, the figure and the button in a cell.
    static let cellSpacing: CGFloat = 6

    /// How far a figure in the Size column may shrink before it starts
    /// truncating. The cells apply this as `.minimumScaleFactor`.
    ///
    /// Settings is NOT inside ``rapidChatDynamicTypeClamp``, so these
    /// `.caption` runs scale with the system text size, and a fixed-width
    /// column plus `lineLimit(1)` means growth eventually clips the
    /// number — which is the defect this column was widened to fix. A
    /// 20% shrink floor buys roughly 1.25x of text growth before that
    /// happens, covering the non-accessibility sizes. It is a bound, not
    /// a Dynamic Type pass: at the AX sizes this table needs to reflow,
    /// which is a change to every column and not this fix's business.
    static let cellMinimumScaleFactor: CGFloat = 0.8

    /// Does a cell of intrinsic width ``needed`` survive ``scale`` times
    /// text growth without truncating, given the shrink floor?
    ///
    /// Deliberately conservative: it grows the WHOLE cell, including the
    /// fixed glyphs and spacing that do not scale. The real cell grows by
    /// less, so a pass here is a real pass; a fail may be pessimistic.
    /// That is the right direction for a guard whose failure mode is a
    /// clipped number.
    static func fits(_ needed: CGFloat, atTextScale scale: CGFloat) -> Bool {
        needed * scale * cellMinimumScaleFactor <= sizeColumnWidth
    }

    /// A `.caption`-sized SF Symbol (state glyph) or the 11pt trash.
    static let glyphWidth: CGFloat = 15

    /// Width a cached cell needs: state glyph + measured size + delete.
    static func cachedCellWidth(size: String) -> CGFloat {
        glyphWidth
            + cellSpacing
            + RecommendedCardLayout.captionWidth(size)
            + cellSpacing
            + glyphWidth
    }

    /// Width a not-cached cell needs: estimate + download glyph. The 8pt
    /// spacing is the one that branch renders.
    static func notCachedCellWidth(size: String) -> CGFloat {
        RecommendedCardLayout.captionWidth("~" + size) + 8 + glyphWidth
    }

    /// Width a serving cell needs: measured size + status + stop-and-delete.
    static func inUseCellWidth(size: String) -> CGFloat {
        RecommendedCardLayout.captionWidth(size)
            + cellSpacing
            + RecommendedCardLayout.captionMediumWidth("Serving")
            + cellSpacing
            + glyphWidth
    }
}
