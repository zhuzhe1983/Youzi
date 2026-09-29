import Foundation

/// Installs the versioned, product-owned helper and skill catalog into the
/// same durable domain store used by every Youzi surface. Loading and package
/// verification happen before the repository transaction, so an invalid or
/// incomplete app bundle cannot partially seed the user's product graph.
struct YouziCapabilityBootstrapper: Sendable {
    private let catalogLoader: YouziBundledCapabilityCatalogLoader
    private let repository: YouziCapabilityRepository

    init(
        store: YouziDomainStore,
        catalogLoader: YouziBundledCapabilityCatalogLoader =
            YouziBundledCapabilityCatalogLoader()
    ) {
        self.catalogLoader = catalogLoader
        self.repository = YouziCapabilityRepository(store: store)
    }

    @discardableResult
    func bootstrap(at date: Date = Date()) throws -> YouziDomainDocument {
        let content = try catalogLoader.load(at: date)
        return try repository.seedCatalog(content.capabilitySeed, at: date)
    }
}
