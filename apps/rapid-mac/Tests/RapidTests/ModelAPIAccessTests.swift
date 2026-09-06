import AppKit
import Testing
@testable import Rapid

@Suite("Model API access")
struct ModelAPIAccessTests {
    @Test("Protocol ports never contain thousands separators", arguments: [8000, 8009, 18000, 65535])
    func address(port: Int) {
        let address = ModelAPIAccess.baseURL(port: port)
        #expect(address == "http://127.0.0.1:" + String(port) + "/v1")
        #expect(!address.contains(","))
        #expect(URLComponents(string: address)?.port == port)
        #expect(ModelAPIAccess.modelsExample(port: port).contains(address + "/models"))
        #expect(ModelAPIAccess.modelsExample(port: port).contains("Bearer $YOUZI_API_KEY"))
    }

    @MainActor
    @Test("No key does not destroy clipboard; expiry only clears the copied revision")
    func clipboard() async throws {
        let clipboard = NSPasteboard.withUniqueName()
        defer { clipboard.releaseGlobally() }
        clipboard.setString("existing", forType: .string)
        let copy = ModelAPIKeyClipboard()
        #expect(!copy.copy(nil, to: clipboard))
        #expect(!copy.copy("", to: clipboard))
        #expect(clipboard.string(forType: .string) == "existing")
        #expect(copy.copy("test-only-not-a-real-key", to: clipboard, lifetime: .milliseconds(20)))
        #expect(clipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true)
        #expect(clipboard.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
        for _ in 0..<100 {
            if clipboard.string(forType: .string) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(clipboard.string(forType: .string) == nil)
        #expect(copy.copy("test-only-not-a-real-key", to: clipboard, lifetime: .milliseconds(20)))
        clipboard.clearContents()
        clipboard.setString("new unrelated copy", forType: .string)
        try await Task.sleep(for: .milliseconds(60))
        #expect(clipboard.string(forType: .string) == "new unrelated copy")
    }
}
