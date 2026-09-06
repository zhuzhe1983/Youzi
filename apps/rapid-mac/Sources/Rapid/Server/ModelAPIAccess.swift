import AppKit

/// Protocol addresses must never pass through localized numeric interpolation.
enum ModelAPIAccess {
    static func baseURL(port: Int) -> String { "http://127.0.0.1:" + String(port) + "/v1" }
    static func modelsExample(port: Int) -> String {
        "curl \"" + baseURL(port: port) + "/models\" \\\n  -H \"Authorization: Bearer $YOUZI_API_KEY\""
    }
}

/// Copy only on explicit user action. Never keep another plaintext copy in UI
/// state, mark as concealed/transient, and expire only OUR clipboard revision.
@MainActor
final class ModelAPIKeyClipboard {
    static let shared = ModelAPIKeyClipboard()
    private var expiry: Task<Void, Never>?

    @discardableResult
    func copy(_ secret: String?, to pasteboard: NSPasteboard = .general,
              lifetime: Duration = .seconds(60)) -> Bool {
        guard let secret, !secret.isEmpty else { return false }
        expiry?.cancel()
        let item = NSPasteboardItem()
        item.setString(secret, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        let revision = pasteboard.changeCount
        expiry = Task {
            do { try await Task.sleep(for: lifetime) } catch { return }
            Self.clearIfUnchanged(pasteboard, revision: revision)
        }
        return true
    }

    static func clearIfUnchanged(_ pasteboard: NSPasteboard, revision: Int) {
        if pasteboard.changeCount == revision { pasteboard.clearContents() }
    }
}
