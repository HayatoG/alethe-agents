import Foundation

/// A syntax or structure error at a byte offset. The reason is a fixed phrase: it never quotes
/// the file, which may hold live credentials.
struct TOMLSyntaxError: Error {
    let offset: Int
    let reason: String
}

/// Where every line of a document sits, so edits can splice bytes instead of re-rendering.
struct TOMLIndex: Sendable {
    enum TriviaKind: Sendable { case blank, comment }

    struct Trivia: Sendable {
        let start: Int
        let kind: TriviaKind
    }

    struct Statement: Sendable {
        let key: [String]
        /// From the line start through its newline (or the end of the file).
        let line: Range<Int>
        let valueRange: Range<Int>
        let value: TOMLValue
    }

    struct Section: Sendable {
        /// Header key path; empty for the root section before the first header.
        let path: [String]
        let isArray: Bool
        /// A `[[array]]` element or a table nested in one: its path alone does not locate it.
        let isArrayScoped: Bool
        /// The header line; `nil` for the root section.
        let header: Range<Int>?
        var statements: [Statement] = []
        /// End of the last statement line, or of the header when there is none.
        var bodyEnd: Int

        var isRoot: Bool { header == nil }
    }

    var sections: [Section]
    /// Blank and comment-only lines, keyed by the offset where the line ends.
    var trivia: [Int: Trivia]
    var root: TOMLTable
    var newline: String
    /// Offset after a byte-order mark.
    var contentStart: Int
}

enum TOMLStep: Hashable, Sendable {
    case key(String)
    case index(Int)
}

private struct BuildFailure: Error {
    let reason: String
}

/// Assembles the value tree from headers and key/value lines, enforcing TOML's rules on
/// redefinition (a table defined twice, a key defined twice, extending an inline table).
private struct TOMLTreeBuilder {
    var root = TOMLTable()
    private(set) var current: [TOMLStep] = []
    private var explicit = Set<[TOMLStep]>()
    private var dotted = Set<[TOMLStep]>()
    private var tableArrays = Set<[TOMLStep]>()

    var currentIsArrayScoped: Bool {
        current.contains { if case .index = $0 { return true } else { return false } }
    }

    mutating func openTable(_ path: [String], isArray: Bool) throws {
        var steps: [TOMLStep] = []
        for key in path.dropLast() {
            let parent = try table(at: steps)
            steps.append(.key(key))
            switch parent[key] {
            case nil:
                set(.table(TOMLTable()), for: key, in: Array(steps.dropLast()))
            case .table(let table)?:
                if table.style == .inline { throw BuildFailure(reason: "an inline table cannot be extended") }
            case .array(let items)? where tableArrays.contains(steps):
                steps.append(.index(items.count - 1))
            default:
                throw BuildFailure(reason: "a key already holds a value")
            }
        }
        guard let key = path.last else { throw BuildFailure(reason: "expected a key") }
        let parentSteps = steps
        let existing = try table(at: parentSteps)[key]
        steps.append(.key(key))
        if isArray {
            switch existing {
            case nil:
                set(.array([.table(TOMLTable())]), for: key, in: parentSteps)
                tableArrays.insert(steps)
                steps.append(.index(0))
            case .array(var items)? where tableArrays.contains(steps):
                items.append(.table(TOMLTable()))
                set(.array(items), for: key, in: parentSteps)
                steps.append(.index(items.count - 1))
            default:
                throw BuildFailure(reason: "a key already holds a value")
            }
        } else {
            switch existing {
            case nil:
                set(.table(TOMLTable()), for: key, in: parentSteps)
            case .table(let table)?:
                if table.style == .inline || explicit.contains(steps) || dotted.contains(steps) {
                    throw BuildFailure(reason: "a table is defined twice")
                }
            default:
                throw BuildFailure(reason: "a key already holds a value")
            }
            explicit.insert(steps)
        }
        current = steps
    }

    mutating func insert(_ key: [String], _ value: TOMLValue) throws {
        var steps = current
        for part in key.dropLast() {
            let parent = try table(at: steps)
            steps.append(.key(part))
            switch parent[part] {
            case nil:
                set(.table(TOMLTable()), for: part, in: Array(steps.dropLast()))
                dotted.insert(steps)
            case .table(let table)? where table.style == .section && dotted.contains(steps):
                continue
            default:
                throw BuildFailure(reason: "a key is defined twice")
            }
        }
        guard let last = key.last else { throw BuildFailure(reason: "expected a key") }
        guard try table(at: steps)[last] == nil else { throw BuildFailure(reason: "a key is defined twice") }
        set(value, for: last, in: steps)
    }

    private func table(at steps: [TOMLStep]) throws -> TOMLTable {
        var table = root
        var rest = steps[...]
        while let step = rest.first {
            rest = rest.dropFirst()
            guard case .key(let key) = step, let child = table[key] else { throw BuildFailure(reason: "internal") }
            if case .index(let position)? = rest.first {
                rest = rest.dropFirst()
                guard case .array(let items) = child, items.indices.contains(position),
                      case .table(let element) = items[position] else { throw BuildFailure(reason: "internal") }
                table = element
            } else {
                guard case .table(let element) = child else { throw BuildFailure(reason: "internal") }
                table = element
            }
        }
        return table
    }

    private mutating func set(_ value: TOMLValue, for key: String, in steps: [TOMLStep]) {
        Self.modify(&root, at: steps[...]) { $0[key] = value }
    }

    private static func modify(_ table: inout TOMLTable, at steps: ArraySlice<TOMLStep>,
                               _ body: (inout TOMLTable) -> Void) {
        guard let step = steps.first else { return body(&table) }
        guard case .key(let key) = step, let child = table[key] else { return }
        var rest = steps.dropFirst()
        if case .index(let position)? = rest.first {
            rest = rest.dropFirst()
            guard case .array(var items) = child, items.indices.contains(position),
                  case .table(var element) = items[position] else { return }
            modify(&element, at: rest, body)
            items[position] = .table(element)
            table[key] = .array(items)
        } else {
            guard case .table(var element) = child else { return }
            modify(&element, at: rest, body)
            table[key] = .table(element)
        }
    }
}

/// A TOML 1.0 parser (with 1.1's multi-line inline tables and `\e`/`\x` escapes) over UTF-8
/// bytes that records the byte range of every header, key/value line and trivia line.
struct TOMLParser {
    private let bytes: [UInt8]
    private var i = 0
    private var builder = TOMLTreeBuilder()
    private static let maxDepth = 100

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    static func parse(_ bytes: [UInt8]) throws -> TOMLIndex {
        var parser = TOMLParser(bytes: bytes)
        return try parser.run()
    }

    // MARK: Lines

    private mutating func run() throws -> TOMLIndex {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        let contentStart = i
        var sections = [TOMLIndex.Section(path: [], isArray: false, isArrayScoped: false, header: nil,
                                          bodyEnd: contentStart)]
        var trivia: [Int: TOMLIndex.Trivia] = [:]

        while i < bytes.count {
            let lineStart = i
            skipSpaces()
            if atLineEnd {
                consumeLineEnd()
                trivia[i] = .init(start: lineStart, kind: .blank)
                continue
            }
            if bytes[i] == ascii("#") {
                try skipComment()
                try finishLine()
                trivia[i] = .init(start: lineStart, kind: .comment)
                continue
            }
            if bytes[i] == ascii("[") {
                let isArray = peek(1) == ascii("[")
                i += isArray ? 2 : 1
                let path = try parseKey()
                try expect("]")
                if isArray { try expect("]") }
                try finishLine()
                do {
                    try builder.openTable(path, isArray: isArray)
                } catch let failure as BuildFailure {
                    throw TOMLSyntaxError(offset: lineStart, reason: failure.reason)
                }
                sections.append(.init(path: path, isArray: isArray, isArrayScoped: builder.currentIsArrayScoped,
                                      header: lineStart..<i, bodyEnd: i))
                continue
            }
            let key = try parseKey()
            try expect("=")
            skipSpaces()
            let valueStart = i
            let value = try parseValue(depth: 0)
            let valueEnd = i
            try finishLine()
            do {
                try builder.insert(key, value)
            } catch let failure as BuildFailure {
                throw TOMLSyntaxError(offset: lineStart, reason: failure.reason)
            }
            sections[sections.count - 1].statements.append(
                .init(key: key, line: lineStart..<i, valueRange: valueStart..<valueEnd, value: value))
            sections[sections.count - 1].bodyEnd = i
        }

        return TOMLIndex(sections: sections, trivia: trivia, root: builder.root, newline: detectNewline(),
                         contentStart: contentStart)
    }

    private func detectNewline() -> String {
        if let newline = bytes.firstIndex(of: 0x0A), newline > 0, bytes[newline - 1] == 0x0D { return "\r\n" }
        return "\n"
    }

    // MARK: Low-level scanning

    private func ascii(_ character: Unicode.Scalar) -> UInt8 { UInt8(ascii: character) }

    private func peek(_ offset: Int) -> UInt8? {
        i + offset < bytes.count ? bytes[i + offset] : nil
    }

    private var atLineEnd: Bool {
        i == bytes.count || bytes[i] == 0x0A || (bytes[i] == 0x0D && peek(1) == 0x0A)
    }

    private mutating func consumeLineEnd() {
        guard i < bytes.count else { return }
        i += bytes[i] == 0x0D ? 2 : 1
    }

    private mutating func skipSpaces() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
    }

    private static func isControl(_ byte: UInt8) -> Bool {
        (byte < 0x20 && byte != 0x09) || byte == 0x7F
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private mutating func skipComment() throws {
        i += 1
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 0x0A || (byte == 0x0D && peek(1) == 0x0A) { return }
            if Self.isControl(byte) { throw TOMLSyntaxError(offset: i, reason: "control character in a comment") }
            i += 1
        }
    }

    /// Trailing spaces, an optional comment, then a newline or the end of the file.
    private mutating func finishLine() throws {
        skipSpaces()
        if i < bytes.count, bytes[i] == ascii("#") { try skipComment() }
        guard atLineEnd else { throw TOMLSyntaxError(offset: i, reason: "expected the end of the line") }
        consumeLineEnd()
    }

    /// Whitespace, newlines and comments inside arrays and inline tables.
    private mutating func skipBlank() throws {
        while true {
            skipSpaces()
            if i < bytes.count, bytes[i] == ascii("#") { try skipComment() }
            if i < bytes.count, bytes[i] == 0x0A {
                i += 1
            } else if i < bytes.count, bytes[i] == 0x0D, peek(1) == 0x0A {
                i += 2
            } else {
                return
            }
        }
    }

    private mutating func expect(_ character: Unicode.Scalar) throws {
        guard i < bytes.count, bytes[i] == ascii(character) else {
            throw TOMLSyntaxError(offset: i, reason: "expected '\(character)'")
        }
        i += 1
    }

    private func hasPrefix(_ text: String) -> Bool {
        let prefix = Array(text.utf8)
        return i + prefix.count <= bytes.count && Array(bytes[i..<(i + prefix.count)]) == prefix
    }

    // MARK: Keys

    private mutating func parseKey() throws -> [String] {
        var parts: [String] = []
        while true {
            skipSpaces()
            parts.append(try parseSimpleKey())
            skipSpaces()
            guard i < bytes.count, bytes[i] == ascii(".") else { return parts }
            i += 1
        }
    }

    private mutating func parseSimpleKey() throws -> String {
        guard i < bytes.count else { throw TOMLSyntaxError(offset: i, reason: "expected a key") }
        if hasPrefix("\"\"\"") || hasPrefix("'''") {
            throw TOMLSyntaxError(offset: i, reason: "a key cannot be a multi-line string")
        }
        if bytes[i] == ascii("\"") { return try parseBasicString() }
        if bytes[i] == ascii("'") { return try parseLiteralString() }
        let start = i
        while i < bytes.count {
            let byte = bytes[i]
            let bare = Self.isDigit(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == ascii("_") || byte == ascii("-")
            guard bare else { break }
            i += 1
        }
        guard i > start else { throw TOMLSyntaxError(offset: i, reason: "expected a key") }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    // MARK: Values

    private mutating func parseValue(depth: Int) throws -> TOMLValue {
        guard depth < Self.maxDepth else { throw TOMLSyntaxError(offset: i, reason: "values are nested too deeply") }
        guard i < bytes.count else { throw TOMLSyntaxError(offset: i, reason: "expected a value") }
        switch bytes[i] {
        case ascii("\""):
            return .string(hasPrefix("\"\"\"") ? try parseMultilineBasicString() : try parseBasicString())
        case ascii("'"):
            return .string(hasPrefix("'''") ? try parseMultilineLiteralString() : try parseLiteralString())
        case ascii("["):
            return try parseArray(depth: depth)
        case ascii("{"):
            return try parseInlineTable(depth: depth)
        default:
            return try parseScalarToken()
        }
    }

    private mutating func parseBasicString() throws -> String {
        let start = i
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            let byte = bytes[i]
            if byte == ascii("\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if byte == ascii("\\") {
                try parseEscape(into: &out)
                continue
            }
            if byte == 0x0A || byte == 0x0D { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            if Self.isControl(byte) { throw TOMLSyntaxError(offset: i, reason: "control character in a string") }
            out.append(byte)
            i += 1
        }
    }

    private mutating func parseEscape(into out: inout [UInt8]) throws {
        let start = i
        i += 1
        guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "invalid escape sequence") }
        let byte = bytes[i]
        i += 1
        switch byte {
        case ascii("b"): out.append(0x08)
        case ascii("t"): out.append(0x09)
        case ascii("n"): out.append(0x0A)
        case ascii("f"): out.append(0x0C)
        case ascii("r"): out.append(0x0D)
        case ascii("e"): out.append(0x1B)
        case ascii("\""), ascii("\\"): out.append(byte)
        case ascii("x"): try appendScalar(hexDigits: 2, into: &out, escapeStart: start)
        case ascii("u"): try appendScalar(hexDigits: 4, into: &out, escapeStart: start)
        case ascii("U"): try appendScalar(hexDigits: 8, into: &out, escapeStart: start)
        default: throw TOMLSyntaxError(offset: start, reason: "invalid escape sequence")
        }
    }

    private mutating func appendScalar(hexDigits count: Int, into out: inout [UInt8], escapeStart: Int) throws {
        guard i + count <= bytes.count,
              let value = UInt32(String(decoding: bytes[i..<(i + count)], as: UTF8.self), radix: 16),
              bytes[i..<(i + count)].allSatisfy({ $0 != ascii("+") && $0 != ascii("-") }),
              let scalar = Unicode.Scalar(value) else {
            throw TOMLSyntaxError(offset: escapeStart, reason: "invalid unicode escape")
        }
        i += count
        out.append(contentsOf: Array(String(Character(scalar)).utf8))
    }

    private mutating func skipOneNewline() {
        if i < bytes.count, bytes[i] == 0x0A {
            i += 1
        } else if i < bytes.count, bytes[i] == 0x0D, peek(1) == 0x0A {
            i += 2
        }
    }

    /// Counts a run of `quote` bytes; three to five close the string, the extras are content.
    private mutating func closingQuotes(_ quote: UInt8, into out: inout [UInt8]) throws -> Bool {
        var run = 0
        while i + run < bytes.count, bytes[i + run] == quote { run += 1 }
        if run >= 3 {
            guard run <= 5 else { throw TOMLSyntaxError(offset: i, reason: "too many quotes") }
            out.append(contentsOf: repeatElement(quote, count: run - 3))
            i += run
            return true
        }
        out.append(contentsOf: repeatElement(quote, count: run))
        i += run
        return false
    }

    private mutating func parseMultilineBasicString() throws -> String {
        let start = i
        i += 3
        skipOneNewline()
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            let byte = bytes[i]
            if byte == ascii("\"") {
                if try closingQuotes(byte, into: &out) { return String(decoding: out, as: UTF8.self) }
                continue
            }
            if byte == ascii("\\") {
                // A backslash ending a line trims the newline and the whitespace that follows.
                var next = i + 1
                while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
                let endsLine = next < bytes.count
                    && (bytes[next] == 0x0A || (bytes[next] == 0x0D && next + 1 < bytes.count && bytes[next + 1] == 0x0A))
                if endsLine {
                    i = next
                    while i < bytes.count {
                        if bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A {
                            i += 1
                        } else if bytes[i] == 0x0D, peek(1) == 0x0A {
                            i += 2
                        } else {
                            break
                        }
                    }
                    continue
                }
                try parseEscape(into: &out)
                continue
            }
            try appendMultilineByte(byte, into: &out)
        }
    }

    /// Appends one content byte of a multi-line string, normalizing CRLF.
    private mutating func appendMultilineByte(_ byte: UInt8, into out: inout [UInt8]) throws {
        if byte == 0x0D {
            guard peek(1) == 0x0A else { throw TOMLSyntaxError(offset: i, reason: "control character in a string") }
            out.append(0x0A)
            i += 2
            return
        }
        if byte != 0x0A, Self.isControl(byte) {
            throw TOMLSyntaxError(offset: i, reason: "control character in a string")
        }
        out.append(byte)
        i += 1
    }

    private mutating func parseLiteralString() throws -> String {
        let start = i
        i += 1
        let contentStart = i
        while true {
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            let byte = bytes[i]
            if byte == ascii("'") {
                let text = String(decoding: bytes[contentStart..<i], as: UTF8.self)
                i += 1
                return text
            }
            if byte == 0x0A || byte == 0x0D { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            if Self.isControl(byte) { throw TOMLSyntaxError(offset: i, reason: "control character in a string") }
            i += 1
        }
    }

    private mutating func parseMultilineLiteralString() throws -> String {
        let start = i
        i += 3
        skipOneNewline()
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated string") }
            let byte = bytes[i]
            if byte == ascii("'") {
                if try closingQuotes(byte, into: &out) { return String(decoding: out, as: UTF8.self) }
                continue
            }
            try appendMultilineByte(byte, into: &out)
        }
    }

    private mutating func parseArray(depth: Int) throws -> TOMLValue {
        let start = i
        i += 1
        var items: [TOMLValue] = []
        while true {
            try skipBlank()
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated array") }
            if bytes[i] == ascii("]") {
                i += 1
                return .array(items)
            }
            items.append(try parseValue(depth: depth + 1))
            try skipBlank()
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated array") }
            if bytes[i] == ascii(",") {
                i += 1
                continue
            }
            if bytes[i] == ascii("]") {
                i += 1
                return .array(items)
            }
            throw TOMLSyntaxError(offset: i, reason: "expected ',' or ']'")
        }
    }

    private mutating func parseInlineTable(depth: Int) throws -> TOMLValue {
        let start = i
        i += 1
        var table = TOMLTable(style: .inline)
        var created = Set<[String]>()
        try skipBlank()
        if i < bytes.count, bytes[i] == ascii("}") {
            i += 1
            return .table(table)
        }
        while true {
            try skipBlank()
            let keyStart = i
            let key = try parseKey()
            try expect("=")
            skipSpaces()
            let value = try parseValue(depth: depth + 1)
            guard Self.insertInline(value, at: key, into: &table, created: &created) else {
                throw TOMLSyntaxError(offset: keyStart, reason: "a key is defined twice")
            }
            try skipBlank()
            guard i < bytes.count else { throw TOMLSyntaxError(offset: start, reason: "unterminated inline table") }
            if bytes[i] == ascii(",") {
                i += 1
                try skipBlank()
                if i < bytes.count, bytes[i] == ascii("}") {
                    i += 1
                    return .table(table)
                }
                continue
            }
            if bytes[i] == ascii("}") {
                i += 1
                return .table(table)
            }
            throw TOMLSyntaxError(offset: i, reason: "expected ',' or '}'")
        }
    }

    private static func insertInline(_ value: TOMLValue, at key: [String], into table: inout TOMLTable,
                                     created: inout Set<[String]>) -> Bool {
        for length in 1..<max(key.count, 1) {
            let prefix = Array(key[..<length])
            switch table.value(at: prefix) {
            case nil:
                table.setValue(.table(TOMLTable(style: .inline)), at: prefix[...], intermediateStyle: .inline)
                created.insert(prefix)
            case .some(.table) where created.contains(prefix):
                continue
            default:
                return false
            }
        }
        guard table.value(at: key) == nil else { return false }
        return table.setValue(value, at: key[...], intermediateStyle: .inline)
    }

    private mutating func parseScalarToken() throws -> TOMLValue {
        let start = i
        func isTokenByte(_ byte: UInt8) -> Bool {
            Self.isDigit(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: ":")
        }
        while i < bytes.count, isTokenByte(bytes[i]) { i += 1 }
        // A date and a time separated by a space form one token.
        if i - start == 10, i + 3 < bytes.count, bytes[start + 4] == ascii("-"), bytes[start + 7] == ascii("-"),
           bytes[i] == 0x20, Self.isDigit(bytes[i + 1]), Self.isDigit(bytes[i + 2]), bytes[i + 3] == ascii(":") {
            i += 1
            while i < bytes.count, isTokenByte(bytes[i]) { i += 1 }
        }
        guard i > start else { throw TOMLSyntaxError(offset: start, reason: "expected a value") }
        let token = Array(bytes[start..<i])
        let text = String(decoding: token, as: UTF8.self)
        switch text {
        case "true": return .boolean(true)
        case "false": return .boolean(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if Self.looksLikeDateTime(token) { return .datetime(text) }
        if let number = Self.number(token) { return number }
        throw TOMLSyntaxError(offset: start, reason: "invalid value")
    }

    private static func looksLikeDateTime(_ token: [UInt8]) -> Bool {
        let date = token.count >= 10 && token[0..<4].allSatisfy(isDigit) && token[4] == UInt8(ascii: "-")
        let time = token.count >= 8 && token[0..<2].allSatisfy(isDigit) && token[2] == UInt8(ascii: ":")
        guard date || time else { return false }
        let allowed = Set("0123456789-:.+TtZz ".utf8)
        return token.allSatisfy { allowed.contains($0) }
    }

    /// Digits with single underscores between them.
    private static func validDigits(_ digits: ArraySlice<UInt8>, _ isValid: (UInt8) -> Bool) -> Bool {
        guard let first = digits.first, let last = digits.last, first != UInt8(ascii: "_"),
              last != UInt8(ascii: "_") else { return false }
        var previousUnderscore = false
        for byte in digits {
            if byte == UInt8(ascii: "_") {
                if previousUnderscore { return false }
                previousUnderscore = true
            } else {
                guard isValid(byte) else { return false }
                previousUnderscore = false
            }
        }
        return true
    }

    private static func number(_ token: [UInt8]) -> TOMLValue? {
        if token.count > 2, token[0] == UInt8(ascii: "0") {
            let radix: Int? = switch token[1] {
            case UInt8(ascii: "x"): 16
            case UInt8(ascii: "o"): 8
            case UInt8(ascii: "b"): 2
            default: nil
            }
            if let radix {
                let digits = token[2...]
                let valid = validDigits(digits) { byte in
                    guard let character = Character(Unicode.Scalar(byte)).hexDigitValue else { return false }
                    return character < radix
                }
                guard valid else { return nil }
                let clean = String(decoding: digits.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
                return Int64(clean, radix: radix).map(TOMLValue.integer)
            }
        }

        var body = token[...]
        if let sign = body.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") { body = body.dropFirst() }
        func scanDigits(from start: Int) -> Int {
            var end = start
            while end < body.endIndex, isDigit(body[end]) || body[end] == UInt8(ascii: "_") { end += 1 }
            return end
        }
        let integerEnd = scanDigits(from: body.startIndex)
        let integerPart = body[body.startIndex..<integerEnd]
        guard validDigits(integerPart, isDigit),
              !(integerPart.count > 1 && integerPart.first == UInt8(ascii: "0")) else { return nil }
        var cursor = integerEnd
        var isFloat = false
        if cursor < body.endIndex, body[cursor] == UInt8(ascii: ".") {
            let fractionEnd = scanDigits(from: cursor + 1)
            guard validDigits(body[(cursor + 1)..<fractionEnd], isDigit) else { return nil }
            cursor = fractionEnd
            isFloat = true
        }
        if cursor < body.endIndex, body[cursor] == UInt8(ascii: "e") || body[cursor] == UInt8(ascii: "E") {
            cursor += 1
            if cursor < body.endIndex, body[cursor] == UInt8(ascii: "+") || body[cursor] == UInt8(ascii: "-") {
                cursor += 1
            }
            let exponentEnd = scanDigits(from: cursor)
            guard validDigits(body[cursor..<exponentEnd], isDigit) else { return nil }
            cursor = exponentEnd
            isFloat = true
        }
        guard cursor == body.endIndex else { return nil }
        let clean = String(decoding: token.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
        if isFloat { return Double(clean).map(TOMLValue.float) }
        return Int64(clean).map(TOMLValue.integer)
    }
}
