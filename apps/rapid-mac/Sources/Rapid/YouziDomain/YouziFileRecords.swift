import Foundation

/// Why a file belongs to the Youzi graph. This is deliberately orthogonal to
/// where its bytes live so moving a managed file does not change its meaning.
enum YouziFileRole: String, Codable, Equatable, Sendable {
    case taskInput
    case projectResource
    case intermediate
    case artifact
    case library
}

/// Last-known ability to resolve the file. Resolution services refresh this
/// metadata; callers must still handle an I/O failure at point of use.
enum YouziFileAvailability: String, Codable, Equatable, Sendable {
    case available
    case missing
    case authorizationRequired
    case staleBookmark
    case revoked
}

/// One authoritative source location. Copies exported by the user do not
/// become owned sources merely because they were produced from this record.
enum YouziFileLocation: Codable, Equatable, Sendable {
    case workspace(workspaceID: UUID, relativePath: String)
    case appManaged(relativePath: String)
    case securityScopedBookmark(data: Data, displayPath: String)
}

struct YouziFile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    /// Uniform Type Identifier when known; kept as a string to make the
    /// persisted schema independent of platform type availability.
    var contentTypeIdentifier: String?
    var byteCount: Int64?
    /// Lowercase hexadecimal SHA-256 of bytes observed when imported/written.
    var sha256: String?
    var role: YouziFileRole
    var originTaskID: UUID?
    var projectID: UUID?
    var location: YouziFileLocation
    var availability: YouziFileAvailability
    let createdAt: Date
    var updatedAt: Date
    var lastVerifiedAt: Date?

    init(
        id: UUID = UUID(),
        displayName: String,
        contentTypeIdentifier: String? = nil,
        byteCount: Int64? = nil,
        sha256: String? = nil,
        role: YouziFileRole,
        originTaskID: UUID? = nil,
        projectID: UUID? = nil,
        location: YouziFileLocation,
        availability: YouziFileAvailability = .available,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastVerifiedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.role = role
        self.originTaskID = originTaskID
        self.projectID = projectID
        self.location = location
        self.availability = availability
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastVerifiedAt = lastVerifiedAt
    }
}
