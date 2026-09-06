import Foundation

/// Owned by the decoder or player, not by a synchronous URL-returning closure.
/// Immutable and shareable; the last owner releases the grant exactly once.
final class YouziMediaFileLease: @unchecked Sendable {
    let url: URL
    private let scope: Scope?

    init(url: URL, scope: Scope? = nil) {
        self.url = url
        self.scope = scope
    }

    final class Scope: @unchecked Sendable {
        private let url: URL
        private let bookmarks: YouziSecurityScopedBookmarkAccess
        private let started: Bool

        init(url: URL, bookmarks: YouziSecurityScopedBookmarkAccess) {
            self.url = url
            self.bookmarks = bookmarks
            started = bookmarks.start(url)
        }

        deinit {
            if started { bookmarks.stop(url) }
        }
    }
}
