import Foundation

/// Versioned, read-only template input bundled with the application.
///
/// This catalog is not a persistence layer. Selecting an entry must be handed
/// to `YouziProductModel`, which owns creation and persistence of the editable
/// task draft. Keeping the resource shape separate from the domain record also
/// prevents release-build timestamps or mutable favorite state from becoming
/// part of the signed catalog.
struct YouziBundledTemplateCatalog: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let resourceName = "youzi-templates-v1"

    var schemaVersion: Int
    var catalogVersion: String
    var templates: [Entry]

    struct Entry: Identifiable, Decodable, Equatable, Sendable {
        var id: UUID
        var name: String
        var category: String
        var summary: String
        var samplePreview: String
        var prefilledRequest: String
        var requiredInputs: [String]
    }

    enum LoadError: Error, Equatable {
        case missingResource
        case unsupportedSchemaVersion(Int)
        case duplicateTemplateID(UUID)
        case emptyRequiredField(templateID: UUID)
    }

    static func loadBundled() throws -> Self {
        guard let url = resourceURL() else { throw LoadError.missingResource }
        let catalog = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        try catalog.validate()
        return catalog
    }

    func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw LoadError.unsupportedSchemaVersion(schemaVersion)
        }

        var seenIDs: Set<UUID> = []
        for template in templates {
            guard seenIDs.insert(template.id).inserted else {
                throw LoadError.duplicateTemplateID(template.id)
            }
            let requiredValues = [
                template.name,
                template.category,
                template.summary,
                template.samplePreview,
                template.prefilledRequest,
            ] + template.requiredInputs
            guard requiredValues.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw LoadError.emptyRequiredField(templateID: template.id)
            }
        }
    }

    private static func resourceURL() -> URL? {
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "json") {
            return url
        }
        return Bundle.module.url(forResource: resourceName, withExtension: "json")
    }
}
