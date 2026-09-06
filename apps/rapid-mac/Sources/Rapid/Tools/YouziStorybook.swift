import Foundation

/// A bounded structured publisher, not an arbitrary HTML/file-writing tool.
/// Escapes all model text and embeds only app-owned artifacts from this task.
enum YouziStorybook {
    static let maxAssetBytes = 20 * 1024 * 1024
    static let maxBookBytes = 64 * 1024 * 1024
    struct Document: Codable {
        let title: String
        let pages: [Page]
    }
    struct Page: Codable {
        let heading: String
        let text: String
        let image_id: UUID?
        let audio_id: UUID?
    }

    static func render(_ book: Document, read: (UUID) throws -> YouziLocalModelTools.Asset) throws -> Data {
        guard !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, book.title.count <= 200,
              (1...8).contains(book.pages.count) else { throw YouziLocalModelTools.Failure.invalid_arguments }
        var sections: [String] = []
        var bytes = 0
        for (index, page) in book.pages.enumerated() {
            guard page.heading.count <= 200, page.text.count <= 8000 else { throw YouziLocalModelTools.Failure.invalid_arguments }
            var media = ""
            if let id = page.image_id {
                let asset = try read(id)
                guard asset.kind == .image, asset.mime == "image/png",
                      asset.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else { throw YouziLocalModelTools.Failure.file_unavailable }
                media += "<img loading=\"lazy\" alt=\"\(escape(page.heading))\" src=\"\(try dataURL(asset, bytes: &bytes))\">"
            }
            if let id = page.audio_id {
                let asset = try read(id)
                guard asset.kind == .audio, asset.mime == "audio/wav", asset.data.starts(with: Array("RIFF".utf8)),
                      asset.data.count >= 12, asset.data[8..<12] == Data("WAVE".utf8) else { throw YouziLocalModelTools.Failure.file_unavailable }
                media += "<audio controls preload=\"none\" aria-label=\"\(escape(page.heading))\" src=\"\(try dataURL(asset, bytes: &bytes))\"></audio>"
            }
            sections.append("""
            <article id="page-\(index + 1)"><div class="number">\(index + 1) / \(book.pages.count)</div>
            <h2>\(escape(page.heading))</h2>\(media)<p>\(escape(page.text))</p></article>
            """)
        }
        let navigation = book.pages.enumerated().map { index, _ in "<a href=\"#page-\(index + 1)\">\(index + 1)</a>" }.joined(separator: " ")
        let html = """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; media-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <title>\(escape(book.title))</title><style>
        :root{color-scheme:light dark;--paper:#fffaf0;--ink:#302a24;--muted:#786b5e;--accent:#9e492b}
        *{box-sizing:border-box}body{margin:0;background:var(--paper);color:var(--ink);font:18px/1.8 system-ui,sans-serif}
        header,main,footer{max-width:780px;margin:auto;padding:24px}header{text-align:center;padding-top:48px}
        h1{font-size:clamp(28px,5vw,44px);line-height:1.3}h2{font-size:26px;line-height:1.4}
        article{padding:24px 0 40px;scroll-margin-top:16px}img{display:block;width:100%;height:auto;border-radius:16px}
        audio{display:block;width:100%;margin:20px 0}p{white-space:pre-wrap;overflow-wrap:anywhere}
        .number,footer{color:var(--muted);font-size:14px}nav a{display:inline-block;padding:6px 14px;color:var(--accent)}
        a:focus-visible,audio:focus-visible{outline:3px solid var(--accent);outline-offset:4px}
        @media(prefers-color-scheme:dark){:root{--paper:#211f1d;--ink:#f5ead9;--muted:#b9ac9c;--accent:#f2ac85}}
        @media print{audio,nav{display:none}article{break-inside:avoid}}
        </style></head><body><header><h1>\(escape(book.title))</h1><nav aria-label="Pages">\(navigation)</nav></header>
        <main>\(sections.joined(separator: "\n"))</main><footer>Youzi · 离线图文话本 / Offline storybook</footer></body></html>
        """
        let data = Data(html.utf8)
        guard data.count <= maxBookBytes else { throw YouziLocalModelTools.Failure.output_too_large }
        return data
    }

    private static func dataURL(_ asset: YouziLocalModelTools.Asset, bytes: inout Int) throws -> String {
        guard !asset.data.isEmpty, asset.data.count <= maxAssetBytes else { throw YouziLocalModelTools.Failure.output_too_large }
        bytes += ((asset.data.count + 2) / 3) * 4
        guard bytes < maxBookBytes - 128_000 else { throw YouziLocalModelTools.Failure.output_too_large }
        return "data:\(asset.mime);base64,\(asset.data.base64EncodedString())"
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
