import Foundation

/// A JSON value that keeps object key order and number spelling, so an agent's config file can be
/// edited and written back without reshuffling or reformatting what Alethe does not own
/// (upstream uses `serde_json::Value` with `preserve_order`).
public enum OrderedJSON: Hashable, Sendable {
    case null
    case bool(Bool)
    /// The literal as written (`1`, `1.0`, `1e3`), never reformatted.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object(OrderedJSONObject)

    public static func integer(_ value: Int) -> OrderedJSON { .number(String(value)) }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [OrderedJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: OrderedJSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let literal) = self else { return nil }
        if let value = Int(literal) { return value }
        return Double(literal).flatMap { Int(exactly: $0) }
    }

    public var doubleValue: Double? {
        if case .number(let literal) = self { return Double(literal) }
        return nil
    }
}

/// Object members in file order. Setting an existing key keeps its position; a new key is appended;
/// removing a key shifts the rest (serde_json `shift_remove`), never swapping.
public struct OrderedJSONObject: Hashable, Sendable, Sequence {
    public struct Member: Hashable, Sendable {
        public var key: String
        public var value: OrderedJSON
    }

    public private(set) var members: [Member]

    public init(_ members: [(String, OrderedJSON)] = []) {
        self.members = []
        for (key, value) in members { self[key] = value }
    }

    public var keys: [String] { members.map(\.key) }
    public var count: Int { members.count }
    public var isEmpty: Bool { members.isEmpty }

    public subscript(key: String) -> OrderedJSON? {
        get { members.first { $0.key == key }?.value }
        set {
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[index].value = newValue } else { members.remove(at: index) }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> OrderedJSON? {
        guard let index = members.firstIndex(where: { $0.key == key }) else { return nil }
        return members.remove(at: index).value
    }

    public func makeIterator() -> IndexingIterator<[Member]> { members.makeIterator() }
}

// MARK: - Parsing

public struct OrderedJSONParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// 1-based position of the offending character.
    public var line: Int
    public var column: Int

    public var description: String { "\(message) at line \(line) column \(column)" }
}

extension OrderedJSON {
    /// Parses strict JSON (RFC 8259). Duplicate keys keep the last value at the first position,
    /// as serde_json does.
    public static func parse(_ text: String) throws(OrderedJSONParseError) -> OrderedJSON {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("trailing characters") }
        return value
    }

    public static func parse(_ data: Data) throws(OrderedJSONParseError) -> OrderedJSON {
        try parse(String(decoding: data, as: UTF8.self))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 512

        func error(_ message: String) -> OrderedJSONParseError {
            var line = 1
            var column = 1
            for byte in bytes[..<min(index, bytes.count)] {
                if byte == UInt8(ascii: "\n") {
                    line += 1
                    column = 1
                } else if byte & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return OrderedJSONParseError(message: message, line: line, column: column)
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func expect(_ literal: String, _ value: OrderedJSON) throws(OrderedJSONParseError) -> OrderedJSON {
            let expected = Array(literal.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("invalid literal")
            }
            index += expected.count
            return value
        }

        mutating func parseValue(depth: Int) throws(OrderedJSONParseError) -> OrderedJSON {
            guard depth < Self.maxDepth else { throw error("nesting too deep") }
            guard let byte = current else { throw error("unexpected end of input") }
            switch byte {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): return try expect("true", .bool(true))
            case UInt8(ascii: "f"): return try expect("false", .bool(false))
            case UInt8(ascii: "n"): return try expect("null", .null)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw error("unexpected character")
            }
        }

        mutating func parseObject(depth: Int) throws(OrderedJSONParseError) -> OrderedJSON {
            index += 1
            var object = OrderedJSONObject()
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try parseString()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { throw error("expected ':'") }
                index += 1
                skipWhitespace()
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"):
                    index += 1
                    return .object(object)
                default: throw error("expected ',' or '}'")
                }
            }
        }

        mutating func parseArray(depth: Int) throws(OrderedJSONParseError) -> OrderedJSON {
            index += 1
            var items: [OrderedJSON] = []
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                switch current {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"):
                    index += 1
                    return .array(items)
                default: throw error("expected ',' or ']'")
                }
            }
        }

        mutating func parseNumber() throws(OrderedJSONParseError) -> OrderedJSON {
            let start = index
            func isDigit(_ byte: UInt8?) -> Bool { byte.map { $0 >= 0x30 && $0 <= 0x39 } ?? false }
            if current == UInt8(ascii: "-") { index += 1 }
            if current == UInt8(ascii: "0") {
                index += 1
            } else if isDigit(current) {
                while isDigit(current) { index += 1 }
            } else {
                throw error("invalid number")
            }
            if current == UInt8(ascii: ".") {
                index += 1
                guard isDigit(current) else { throw error("invalid number") }
                while isDigit(current) { index += 1 }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard isDigit(current) else { throw error("invalid number") }
                while isDigit(current) { index += 1 }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        mutating func parseString() throws(OrderedJSONParseError) -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var runStart = index
            func flush(_ end: Int, into scalars: inout String.UnicodeScalarView) {
                if end > runStart { scalars.append(contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).unicodeScalars) }
            }
            while true {
                guard let byte = current else { throw error("unterminated string") }
                if byte == UInt8(ascii: "\"") {
                    flush(index, into: &scalars)
                    index += 1
                    return String(scalars)
                }
                if byte < 0x20 { throw error("control character in string") }
                if byte != UInt8(ascii: "\\") {
                    index += 1
                    continue
                }
                flush(index, into: &scalars)
                index += 1
                guard let escape = current else { throw error("unterminated string") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let unit = try parseHex4()
                    if (0xD800..<0xDC00).contains(unit) {
                        guard current == UInt8(ascii: "\\"), index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("lone surrogate")
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00..<0xE000).contains(low),
                              let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) else {
                            throw error("lone surrogate")
                        }
                        scalars.append(scalar)
                    } else if let scalar = Unicode.Scalar(unit) {
                        scalars.append(scalar)
                    } else {
                        throw error("lone surrogate")
                    }
                default: throw error("invalid escape")
                }
                runStart = index
            }
        }

        mutating func parseHex4() throws(OrderedJSONParseError) -> UInt32 {
            guard index + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                throw error("invalid \\u escape")
            }
            index += 4
            return value
        }
    }
}

// MARK: - Rendering

extension OrderedJSON {
    /// Pretty output in serde_json's `to_string_pretty` shape: two-space indent, `"key": value`,
    /// empty containers as `{}`/`[]`, slashes and non-ASCII unescaped.
    public func rendered() -> String {
        var output = ""
        render(into: &output, indent: 0)
        return output
    }

    private func render(into output: inout String, indent: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let literal): output += literal
        case .string(let value): Self.renderString(value, into: &output)
        case .array(let items):
            guard !items.isEmpty else { output += "[]"; return }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                item.render(into: &output, indent: indent + 1)
                output += offset == items.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "]"
        case .object(let object):
            guard !object.isEmpty else { output += "{}"; return }
            output += "{\n"
            for (offset, member) in object.members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                Self.renderString(member.key, into: &output)
                output += ": "
                member.value.render(into: &output, indent: indent + 1)
                output += offset == object.count - 1 ? "\n" : ",\n"
            }
            output += String(repeating: "  ", count: indent) + "}"
        }
    }

    private static func renderString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += "\\u" + String(format: "%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Codable bridge

extension OrderedJSON {
    /// Encodes a model value (key order follows the encoder; sorted for a stable output).
    public init<Value: Encodable>(encoding value: Value) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self = try OrderedJSON.parse(try encoder.encode(value))
    }

    public func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        try JSONDecoder().decode(type, from: Data(rendered().utf8))
    }
}
