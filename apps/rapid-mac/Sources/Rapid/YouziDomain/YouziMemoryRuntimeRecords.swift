import CryptoKit
import Foundation

/// Admission is NOT confirmation: legacy facts remain usable under the user's
/// existing opt-in, without inventing a confirmation date or confidence score.
enum YouziMemoryContextAdmission: String, Codable, Equatable, Sendable {
    case legacyCompatible
}

struct YouziLegacyMemoryMetadata: Codable, Equatable, Sendable {
    var entryID: UUID
    var evidenceCount: Int
    var sourceConversationIDs: [UUID]
}

struct YouziMemoryControl: Codable, Equatable, Sendable {
    var legacyImportCompleted = false
    var importedLegacyIDs: [UUID] = []
    var forgottenLegacyIDs: [UUID] = []
    var excludedConversationIDs: [UUID] = []
    var blockedMessageIDs: [UUID] = []
    var forgottenFingerprints: [String] = []
    var collectionNotBefore: Date?
    // A local random key prevents the tombstone list being a dictionary of
    // unsalted personal facts. It contains no source text and is never exported.
    var fingerprintKey = UUID().uuidString + UUID().uuidString
}

struct YouziMemoryChatSource: Codable, Equatable, Sendable {
    let conversationID: UUID
    let messageID: UUID
    let title: String
    let text: String
    let createdAt: Date

    var locator: String { "conversation:\(conversationID.uuidString)/message:\(messageID.uuidString)" }

    static func reference(_ locator: String) -> (conversation: UUID, message: UUID?)? {
        let parts = locator.components(separatedBy: "/message:")
        guard parts[0].hasPrefix("conversation:"),
              let conversation = UUID(uuidString: String(parts[0].dropFirst("conversation:".count)))
        else { return nil }
        return (conversation, parts.count == 2 ? UUID(uuidString: parts[1]) : nil)
    }
}

struct YouziMemoryCandidate: Equatable, Sendable {
    let content: String
    let kind: YouziMemoryNodeKind
    let messageID: UUID
    let quote: String
}

struct YouziMemoryContextRequest: Equatable, Sendable {
    var query: String = ""
    var projectID: UUID?
    var workspaceID: UUID?
    var characterBudget = 2_000
    var maximumNodes = 8
    var now = Date()
}

enum YouziMemoryError: LocalizedError {
    case storageUnavailable(String)
    case invalidLegacy
    case invalidContent
    case missingRecord
    case missingEvidence
    case identityCollision

    var errorDescription: String? {
        switch self {
        case .storageUnavailable(let reason): return reason
        case .invalidLegacy: return "旧记忆文件无法安全导入，原文件已保留。 / Legacy memory could not be safely imported; the original is preserved."
        case .invalidContent: return "请输入 1–2000 字的记忆。 / Enter 1–2000 characters."
        case .missingRecord: return "这条记忆已不存在。 / This memory no longer exists."
        case .missingEvidence: return "候选记忆缺少有效的用户消息依据。 / Missing valid user-message evidence."
        case .identityCollision: return "旧记忆身份与已有记录冲突，未覆盖任何数据。 / Legacy identity collision; no data was overwritten."
        }
    }
}

extension YouziMemoryNode {
    var isVisibleMemory: Bool { state != .forgotten && state != .superseded }
    var isContextAdmitted: Bool {
        isVisibleMemory && (state == .confirmed || contextAdmission == .legacyCompatible)
    }
}

enum YouziMemoryText {
    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func fingerprint(_ text: String, key: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(normalized(text).utf8),
            using: SymmetricKey(data: Data(key.utf8))).map { String(format: "%02x", $0) }.joined()
    }

    static func checksum(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Unicode word + bigram matching also handles Chinese without requiring a
    /// downloaded embedding model. This is lexical retrieval, not semantic RAG.
    static func terms(_ text: String) -> Set<String> {
        let normalized = normalized(text)
        let words = normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
        var result = Set(words.filter { $0.count > 1 })
        for word in words where word.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
            let chars = Array(word)
            if chars.count > 1 {
                for i in 0..<(chars.count - 1) { result.insert(String(chars[i...i+1])) }
            }
        }
        return result
    }
}
