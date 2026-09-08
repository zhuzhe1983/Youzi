import AppKit
import SwiftUI
import Testing
@testable import Rapid

@MainActor
@Suite("Markdown table column fill", .serialized)
struct MarkdownTableLayoutTests {
    private var fixture: MarkdownItem.TableBlock {
        .init(header: [[], [InlineRun(text: "A")], [InlineRun(text: "B")]], rows: [
            [[InlineRun(text: "短项")], [InlineRun(text: "用于核对列宽的较长内容，不是模型输出")], [InlineRun(text: "另一个比表头更长的说明")]],
            [[InlineRun(text: "第二行")], [InlineRun(text: "短")], [InlineRun(text: "第三列里的宽内容：一二三四五六七八")]],
            [[InlineRun(text: "结尾")], [InlineRun(text: "中间")], [InlineRun(text: "终点")]]
        ], alignments: [.leading, .center, .trailing])
    }

    @Test("Empty/short headers fill their column; dividers span every row and column",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MARKDOWN_TABLE_RENDER"] == "1"))
    func cellFill() async throws {
        var options = MarkdownOptions()
        // Diagnostic colors let the assertions measure painted cells/borders,
        // not text width or antialiased glyphs. This is the production view.
        options.tableHeaderBackgroundColor = .red
        options.tableBorderColor = .green
        let bitmap = try await render(fixture, options: options, scheme: .dark,
            width: 880, height: 260, name: "diagnostic")
        try verifyGrid(bitmap, horizontalEdges: 5, verticalEdges: 4)
        var tall = fixture
        tall.rows[1][1] = [InlineRun(text: "多行内容\n第二行\n第三行")]
        let tallBitmap = try await render(tall, options: options, scheme: .dark,
            width: 880, height: 320, name: "diagnostic-tall")
        try verifyGrid(tallBitmap, horizontalEdges: 5, verticalEdges: 4)
    }

    @Test("Real chat theme renders light/dark, narrow scrolling, and small/extra-large text",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MARKDOWN_TABLE_RENDER"] == "1"))
    func themed() async throws {
        for scheme in [ColorScheme.light, .dark] {
            for size in [YouziFontSize.small, .extraLarge] {
                var options = MarkdownOptions()
                options.tablePointSize = round(14 * size.scale)
                let suffix = "\(scheme == .dark ? "dark" : "light")-\(size.rawValue)"
                _ = try await render(fixture, options: options, scheme: scheme,
                    width: 1020, height: 280, name: "theme-" + suffix)
                _ = try await render(fixture, options: options, scheme: scheme,
                    width: 420, height: 280, name: "narrow-" + suffix)
            }
        }
    }

    @Test("Chat keeps streaming and completed messages on the native TextKit table path")
    func rendererContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let chat = try String(contentsOf: root.appendingPathComponent("Sources/Rapid/UI/ChatView.swift"), encoding: .utf8)
        #expect(chat.contains("StreamingTextKitMarkdownView("))
        #expect(chat.contains("TextKitMarkdownView(content: message.content)"))
        let source = "| | A | B |\n| :--- | :---: | ---: |\n| **Bold** | `code` | 123 |"
        let result = TextKitMarkdownView.compile(source)
        let table = try #require(result.items.compactMap { item -> MarkdownItem.TableBlock? in
            if case .table(let block) = item { return block }; return nil
        }.first)
        #expect(table.alignments == [.leading, .center, .trailing])
        #expect(table.header[0].allSatisfy { $0.text.isEmpty })
        #expect(table.rows[0][0].contains { $0.isStrong })
        #expect(table.rows[0][1].contains { $0.isInlineCode })
        #expect(table.accessibilityModel != nil)
    }

    private func render(_ block: MarkdownItem.TableBlock, options: MarkdownOptions,
                        scheme: ColorScheme, width: CGFloat, height: CGFloat, name: String) async throws -> NSBitmapImageRep {
        let view = MarkdownTableView(block: block, options: options)
            .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            .environment(\.colorScheme, scheme)
            .padding(20).frame(width: width, height: height, alignment: .topLeading)
            .background(scheme == .dark ? Color.black : Color.white)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        #expect(host.fittingSize.width <= width + 1)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOUZI_MARKDOWN_TABLE_RENDER_DIR"] ?? "/tmp/youzi-markdown-table-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent(name + ".png"))
        return bitmap
    }

    private func verifyGrid(_ bitmap: NSBitmapImageRep, horizontalEdges: Int, verticalEdges: Int) throws {
        let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
        var green = [Bool](repeating: false, count: width * height)
        var red = green
        var left = width, right = 0, top = height, bottom = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let index = y * width + x
                // NSHostingView bitmaps use the display's color profile: pure
                // diagnostic colors need not remain RGB (0, 1, 0)/(1, 0, 0).
                // Channel dominance survives that conversion, unlike equality.
                green[index] = c.greenComponent > 0.6 && c.greenComponent > c.redComponent * 1.4
                    && c.greenComponent > c.blueComponent * 1.4
                red[index] = c.redComponent > 0.6 && c.redComponent > c.greenComponent * 1.4
                    && c.redComponent > c.blueComponent * 1.4
                if green[index] {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        try #require(right > left + 80 && bottom > top + 80)
        // Exclude rounded outer corners and sample header padding, not glyphs.
        let inset = 20, sampleY = top + 6
        let headerPixels = ((left + inset)...(right - inset)).filter { x in
            red[sampleY * width + x] || green[sampleY * width + x]
        }.count
        #expect(Double(headerPixels) / Double(right - left - 2 * inset + 1) > 0.99,
                "Header background must cover the complete width, even when empty or shorter than the body")
        let horizontal = (top...bottom).map { y in
            let count = ((left + inset)...(right - inset)).filter { green[y * width + $0] }.count
            return Double(count) / Double(right - left - 2 * inset + 1) > 0.99
        }
        let vertical = (left...right).map { x in
            let count = ((top + inset)...(bottom - inset)).filter { green[$0 * width + x] }.count
            return Double(count) / Double(bottom - top - 2 * inset + 1) > 0.99
        }
        #expect(bands(horizontal) == horizontalEdges, "Every shared row edge must span the complete table")
        #expect(bands(vertical) == verticalEdges, "Column dividers must stay aligned for leading/center/trailing cells")
    }

    private func bands(_ pixels: [Bool]) -> Int {
        var previous = false, count = 0
        for pixel in pixels {
            if pixel && !previous { count += 1 }
            previous = pixel
        }
        return count
    }
}
