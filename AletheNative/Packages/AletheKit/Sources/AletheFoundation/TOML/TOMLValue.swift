import Foundation

/// A TOML value as read from, or written into, a `TOMLDocument`.
public enum TOMLValue: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case boolean(Bool)
    /// Offset or local date-times, dates and times, kept as written.
    case datetime(String)
    case array([TOMLValue])
    case table(TOMLTable)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var integerValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }

    /// A float, or an integer widened to one.
    public var doubleValue: Double? {
        switch self {
        case .float(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var arrayValue: [TOMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var tableValue: TOMLTable? {
        if case .table(let value) = self { return value }
        return nil
    }

    /// The string elements of an array, skipping anything else; `nil` when this is not an array.
    public var stringArrayValue: [String]? {
        arrayValue?.compactMap(\.stringValue)
    }

    /// The value as TOML source on one line (tables inline), e.g. for `codex -c key=value`.
    public var tomlText: String { TOMLRender.inline(self) }
}

extension TOMLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: TOMLValue...) { self = .array(elements) }
}

/// An ordered TOML table. Equality ignores key order and `style`.
public struct TOMLTable: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    /// How a table new to a document is written: its own `[header]` section or `{ inline }`.
    /// Parsed tables carry the style they were written in; an existing table keeps its style
    /// when it is edited.
    public enum Style: Hashable, Sendable {
        case section
        case inline
    }

    public var style: Style
    public private(set) var keys: [String] = []
    private var values: [String: TOMLValue] = [:]

    public init(style: Style = .section) {
        self.style = style
    }

    public init(_ entries: [(String, TOMLValue)], style: Style = .section) {
        self.style = style
        for (key, value) in entries { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, TOMLValue)...) {
        self.init(elements)
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    public var entries: [(key: String, value: TOMLValue)] {
        keys.compactMap { key in values[key].map { (key, $0) } }
    }

    /// Setting a new key appends it; setting an existing one keeps its position; `nil` removes it.
    public subscript(key: String) -> TOMLValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// The value at a key path through nested tables; the empty path is this table.
    public func value<Path: Collection<String>>(at path: Path) -> TOMLValue? {
        guard let first = path.first else { return .table(self) }
        guard let child = self[first] else { return nil }
        let rest = path.dropFirst()
        if rest.isEmpty { return child }
        guard case .table(let table) = child else { return nil }
        return table.value(at: rest)
    }

    /// Sets (or with `nil` removes) the value at a key path, creating missing intermediate tables
    /// with `intermediateStyle`. Returns `false` when an intermediate key holds a non-table value.
    @discardableResult
    public mutating func setValue(_ value: TOMLValue?, at path: ArraySlice<String>,
                                  intermediateStyle: Style = .section) -> Bool {
        guard let first = path.first else { return false }
        let rest = path.dropFirst()
        if rest.isEmpty {
            self[first] = value
            return true
        }
        var child: TOMLTable
        switch self[first] {
        case .table(let table)?: child = table
        case nil:
            guard value != nil else { return false }
            child = TOMLTable(style: intermediateStyle)
        default: return false
        }
        guard child.setValue(value, at: rest, intermediateStyle: intermediateStyle) else { return false }
        self[first] = .table(child)
        return true
    }

    public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
        lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(values)
    }
}

/// Key and value rendering shared by the document editor and callers building TOML arguments.
public enum TOMLRender {
    /// A key, bare when it can be, otherwise as a basic string.
    public static func key(_ key: String) -> String {
        let bare = !key.isEmpty && key.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
        return bare ? key : string(key)
    }

    /// A dotted key path, as in a `[header]` or a `-c` override.
    public static func keyPath(_ path: [String]) -> String {
        path.map(key).joined(separator: ".")
    }

    public static func string(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// One value on one line; tables are written inline whatever their style.
    public static func inline(_ value: TOMLValue) -> String {
        switch value {
        case .string(let text): return string(text)
        case .integer(let number): return String(number)
        case .float(let number):
            if number.isNaN { return "nan" }
            if number.isInfinite { return number < 0 ? "-inf" : "inf" }
            let text = String(number)
            return text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) ? text : text + ".0"
        case .boolean(let flag): return flag ? "true" : "false"
        case .datetime(let text): return text
        case .array(let items):
            return "[" + items.map(inline).joined(separator: ", ") + "]"
        case .table(let table):
            if table.isEmpty { return "{}" }
            return "{ " + table.entries.map { key($0.key) + " = " + inline($0.value) }.joined(separator: ", ") + " }"
        }
    }
}
