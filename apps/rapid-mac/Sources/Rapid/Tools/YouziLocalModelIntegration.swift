import Foundation

extension YouziLocalModelTools {
    /// Preserve alias-keyed settings while addressing older runtimes by HF ID.
    static func synthesizeLocally(text: String, entry: ModelEntry, voice: String?, port: Int,
                                  bearer: String?, client: AudioClient = AudioClient()) async throws -> SynthesizedAudio {
        let modelID = speechModelID(entry)
        let available = try await client.voices(model: modelID, port: port, bearer: bearer)
        let resolvedVoice: String?
        if let voice {
            // Language names (e.g. Chinese) are not speaker IDs. Never send an
            // invented speaker to the runtime or silently replace a requested one.
            guard let canonical = available.first(where: { $0.caseInsensitiveCompare(voice) == .orderedSame }) else {
                throw Failure.invalid_voice
            }
            resolvedVoice = canonical
        } else {
            resolvedVoice = client.generationDefaults.voice(for: entry.alias, available: available)
        }
        return try await client.synthesize(text: text, model: modelID, voice: resolvedVoice, port: port, bearer: bearer)
    }

    /// Weak captures avoid app → chat → tools → app cycles. Every call captures
    /// its task before awaits; changing the selected chat cannot redirect output.
    static func desktop(server: ServerManager, chat: ChatViewModel, product: YouziProductModel, downloads: DownloadManager) -> YouziLocalModelTools {
        YouziLocalModelTools(dependencies: Dependencies(
            catalog: { [weak server, weak downloads] in
                guard let server, let binary = server.binaryPath,
                      let media = await ModelCatalog.scenarioMediaEntries(binary: binary) else { throw Failure.catalog_unavailable }
                let chat = await ModelCatalogCache.shared.entries(binary: binary, generation: downloads?.cacheGeneration ?? 0)
                return YouziScenarioModels.merge(chat: chat, media: media)
            },
            snapshot: { [weak server] in
                await server?.refreshResidency()
                return server?.residency ?? .empty
            },
            load: { [weak server] entry in
                guard let server, server.servingAlias != nil else { return false }
                return await server.ensureServing(alias: entry.alias, hfPath: entry.hfRepo,
                    residencyEligible: true, requestIsMedia: true, mediaKind: entry.kind)
            },
            image: { [weak server] prompt, entry, size in
                guard let server, server.servingAlias != nil else { throw Failure.model_not_ready }
                let images = try await ImageClient().generate(prompt: prompt, model: entry.alias, size: size,
                    count: 1, seed: nil, port: server.activePort, bearer: server.activeBearer)
                guard let image = images.first else { throw Failure.generation_failed }
                return image.pngData
            },
            speech: { [weak server] text, entry, voice in
                guard let server, server.servingAlias != nil else { throw Failure.model_not_ready }
                return try await synthesizeLocally(text: text, entry: entry, voice: voice,
                    port: server.activePort, bearer: server.activeBearer)
            },
            context: { [weak chat, weak product] in
                guard let chat, let product,
                      let task = product.tasks.first(where: { $0.conversationID == chat.activeConversationID }) else { return nil }
                return Context(taskID: task.id, projectID: task.projectID, turnID: chat.messages.last(where: { $0.role == .user })?.id)
            },
            save: { [weak product] data, name, contentType, kind, context in
                guard let product, product.task(id: context.taskID) != nil,
                      let artifact = product.createArtifact(data: data, named: name, contentTypeIdentifier: contentType,
                        kind: kind, taskID: context.taskID, projectID: context.projectID) else { throw Failure.file_unavailable }
                return Saved(artifactID: artifact.id, fileID: artifact.fileID, name: artifact.title)
            },
            read: { [weak product] id, context in
                guard let product, let artifact = product.artifact(id: id), artifact.taskID == context.taskID,
                      let file = product.file(for: artifact), case .appManaged = file.location,
                      artifact.kind == .image || artifact.kind == .audio else { throw Failure.file_unavailable }
                return try product.withFileURL(id: file.id) { url in
                    let size = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                    guard size.isSymbolicLink != true, let count = size.fileSize, count <= YouziStorybook.maxAssetBytes else { throw Failure.output_too_large }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    return Asset(id: artifact.id, name: artifact.title, kind: artifact.kind,
                                 mime: artifact.kind == .image ? "image/png" : "audio/wav", data: data)
                }
            },
            voices: { [weak server] entry in
                guard let server else { throw Failure.model_not_ready }
                return try await AudioClient().voices(model: speechModelID(entry),
                    port: server.activePort, bearer: server.activeBearer)
            }
        ))
    }
}
