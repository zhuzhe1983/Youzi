import Foundation

/// Matches the local /images/generations contract: 256...2048, multiples of 16.
/// Each side uses the nearest legal value; exact half steps round upward.
struct YouziImageSize: Equatable {
    let requested: String
    let effective: String
    var adjusted: Bool { requested != effective }

    init?(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "*", with: "x")
        let parts = value.split(separator: "x", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else { return nil }
        func align(_ side: Int) -> Int { min(2048, max(256, ((side + 8) / 16) * 16)) }
        requested = "\(width)x\(height)"
        effective = "\(align(width))x\(align(height))"
    }
}
