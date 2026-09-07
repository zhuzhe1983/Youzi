import Foundation

/// Incremental, conservative speech projection of assistant *content* deltas.
/// Tool payloads/reasoning are never inputs. Markdown code, JSON and explicit
/// reasoning tags are also suppressed defensively, including split delimiters.
/// This is intentionally not a general Markdown renderer.
struct LiveVoiceSentenceSegmenter {
    private enum Mode {
        case prose, code(Character, Int), hidden(String), json(Int, Bool, Bool)
    }
    private var mode: Mode = .prose
    private var input = ""
    private var prose = ""
    private(set) var discardedOversizeInput = false
    let maximumCharacters: Int

    init(maximumCharacters: Int = 280) { self.maximumCharacters = max(40, maximumCharacters) }

    mutating func append(_ delta: String) -> [String] {
        var result: [String] = []
        // A bounded lexer carry, even for an unterminated tag/link. Chunking also
        // prevents a large final content snapshot from growing temporary state.
        for char in delta {
            input.append(char)
            result += consume(final: false)
            if input.count > 4096 {
                input = ""
                mode = .hidden("__oversize_unterminated_markup__")
                discardedOversizeInput = true
            }
        }
        return result
    }

    mutating func finish() -> [String] {
        var result = consume(final: true)
        let tail = Self.clean(prose)
        if !tail.isEmpty { result.append(tail) }
        input = ""; prose = ""; mode = .prose
        return result
    }

    private mutating func consume(final: Bool) -> [String] {
        var result: [String] = []
        while let char = input.first {
            switch mode {
            case .code(let marker, let count):
                if char == marker {
                    let run = input.prefix(while: { $0 == marker }).count
                    if run == input.count && !final { return result }
                    input.removeFirst(run)
                    if run >= count { mode = .prose; prose.append(" ") }
                } else { input.removeFirst() }
            case .hidden(let tag):
                let closing = "</\(tag)>"
                if input.lowercased().hasPrefix(closing) {
                    input.removeFirst(closing.count); mode = .prose
                } else if closing.hasPrefix(input.lowercased()) && !final {
                    return result
                } else { input.removeFirst() }
            case .json(let depth, let quoted, let escaped):
                input.removeFirst()
                if escaped { mode = .json(depth, quoted, false) }
                else if quoted && char == "\\" { mode = .json(depth, true, true) }
                else if char == "\"" { mode = .json(depth, !quoted, false) }
                else if !quoted && (char == "{" || char == "[") { mode = .json(depth + 1, false, false) }
                else if !quoted && (char == "}" || char == "]") {
                    mode = depth <= 1 ? .prose : .json(depth - 1, false, false)
                    if depth <= 1 { prose.append(" ") }
                }
            case .prose:
                if char == "`" || char == "~" {
                    let run = input.prefix(while: { $0 == char }).count
                    if run == input.count && !final { return result }
                    input.removeFirst(run)
                    if char == "`" || run >= 3 { mode = .code(char, run) }
                    continue
                }
                if char == "<" {
                    guard let end = input.firstIndex(of: ">") else {
                        if final { input = "" }; return result
                    }
                    let rawTag = String(input[input.index(after: input.startIndex)..<end]).lowercased()
                    let tag = rawTag.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                    input.removeSubrange(...end)
                    if ["think", "thinking", "analysis", "reasoning", "tool_call", "tool_response", "code", "pre", "script", "style"].contains(tag) {
                        mode = .hidden(tag)
                    }
                    continue
                }
                if char == "{" { input.removeFirst(); mode = .json(1, false, false); continue }
                if char == "[" {
                    guard input.count > 1 else { if final { input = "" }; return result }
                    let next = input.dropFirst().first!
                    if next == "{" || next == "[" || next == "\"" || next.isNumber || next.isWhitespace || next == "-" {
                        input.removeFirst(); mode = .json(1, false, false); continue
                    }
                    guard let end = input.firstIndex(of: "]") else {
                        if final { input = "" }; return result
                    }
                    // A leading t/f/n is also ordinary Markdown ("the guide").
                    // Suppress complete JSON literals, not their first letters.
                    let firstValue = input.dropFirst().prefix { !$0.isWhitespace && $0 != "," && $0 != "]" }
                    if ["true", "false", "null"].contains(String(firstValue)) {
                        input.removeFirst(); mode = .json(1, false, false); continue
                    }
                    let after = input.index(after: end)
                    if after == input.endIndex && !final { return result }
                    let label = String(input[input.index(after: input.startIndex)..<end])
                    if after < input.endIndex && input[after] == "(" {
                        guard let close = input[after...].firstIndex(of: ")") else {
                            if final { input = "" }; return result
                        }
                        input.removeSubrange(...close)
                    } else { input.removeSubrange(...end) }
                    // Labels can contain code; run through the same lexer rather
                    // than letting bracket syntax bypass suppression.
                    var labelFilter = LiveVoiceSentenceSegmenter(maximumCharacters: maximumCharacters)
                    prose += (labelFilter.append(label) + labelFilter.finish()).joined(separator: " ")
                    continue
                }
                input.removeFirst()
                prose.append(char)
                if Self.isBoundary(prose) || prose.count >= maximumCharacters {
                    // A long unpunctuated word waits for whitespace rather than
                    // spelling fragments aloud; cap/drop pathological tokens.
                    if prose.count >= maximumCharacters && !char.isWhitespace
                        && !"。！？；!?".contains(char) {
                        if prose.count > maximumCharacters * 4 { prose = "" }
                        continue
                    }
                    let sentence = Self.clean(prose)
                    if !sentence.isEmpty { result.append(sentence) }
                    prose = ""
                }
            }
        }
        return result
    }

    private static func isBoundary(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if "。！？；".contains(last) { return true }
        guard last.isWhitespace else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let punctuation = trimmed.last, ".!?;".contains(punctuation) else { return false }
        if punctuation == "." {
            let token = trimmed.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
            if ["mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "vs.", "etc."].contains(token) { return false }
            if token.count == 2, token.first?.isLetter == true { return false }
        }
        return true
    }

    private static func clean(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in [
            (#"https?://\S+"#, ""),
            (#"(?m)^\s*(?:#{1,6}\s*|>\s*|[-*+]\s+|\d+[.)]\s+)"#, ""),
            (#"[*_~]"#, ""),
            (#"\s+"#, " ")
        ] { result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tables, TeX, or leftover structural JSON are not natural spoken prose.
        guard !result.contains("|"), !result.contains("\\"), !result.contains("{"),
              result.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return result
    }
}
