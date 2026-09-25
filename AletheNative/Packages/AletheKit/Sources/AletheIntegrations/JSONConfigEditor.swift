import AletheFoundation
import Foundation

public enum JSONConfigError: Error, Equatable, Sendable {
    /// The text is not JSON (with the parser's line and column).
    case unparsable(OrderedJSONParseError)
    /// The top-level value is not an object.
    case rootNotAnObject
    /// A key on the path holds something other than an object; it is never replaced blindly.
    case notAnObject(path: [String])
    case emptyPath
}

/// Edits one key path of an agent's JSON config and keeps everything else — unknown keys, their
/// order, number spelling (upstream `mcp_agents.rs` `json_root`/`json_upsert`/`json_remove`/
/// `json_render`). The output is pretty JSON with a trailing newline, as upstream writes it.
///
/// Comments in a JSONC source are accepted for reading (`allowComments`) but are not preserved:
/// callers must not write a `.jsonc` file back through this editor (upstream refuses them too).
public struct JSONConfigEditor: Sendable, Equatable {
    public private(set) var root: OrderedJSONObject

    public init(root: OrderedJSONObject = OrderedJSONObject()) {
        self.root = root
    }

    /// An empty or whitespace-only file is an empty object.
    public init(parsing text: String, allowComments: Bool = false) throws(JSONConfigError) {
        let source = allowComments ? JSONC.strip(text) : text
        guard !source.allSatisfy(\.isWhitespace) else {
            self.init()
            return
        }
        let value: OrderedJSON
        do {
            value = try OrderedJSON.parse(source)
        } catch {
            throw .unparsable(error)
        }
        guard case .object(let object) = value else { throw .rootNotAnObject }
        self.init(root: object)
    }

    public init(parsing data: Data, allowComments: Bool = false) throws(JSONConfigError) {
        try self.init(parsing: String(decoding: data, as: UTF8.self), allowComments: allowComments)
    }

    public func value(at path: [String]) -> OrderedJSON? {
        guard let last = path.last else { return .object(root) }
        var object = root
        for key in path.dropLast() {
            guard let next = object[key]?.objectValue else { return nil }
            object = next
        }
        return object[last]
    }

    /// Sets the value at `path`, creating missing intermediate objects. An existing key keeps its
    /// position; a new one is appended to its object.
    public mutating func set(_ value: OrderedJSON, at path: [String]) throws(JSONConfigError) {
        guard !path.isEmpty else { throw .emptyPath }
        try Self.update(&root, path: path[...], fullPath: path, create: true) { object, key in
            object[key] = value
        }
    }

    /// Removes the key at `path` and returns what it held; `nil` when it was absent. Intermediate
    /// objects left empty are kept, as upstream does.
    @discardableResult
    public mutating func remove(at path: [String]) throws(JSONConfigError) -> OrderedJSON? {
        guard !path.isEmpty else { throw .emptyPath }
        var removed: OrderedJSON?
        try Self.update(&root, path: path[...], fullPath: path, create: false) { object, key in
            removed = object.removeValue(forKey: key)
        }
        return removed
    }

    /// Rewrites only `managed` keys of the object at `path` (creating it when missing) and keeps
    /// every other key the user added: managed keys are removed, then `values` are set in order
    /// (upstream `json_upsert`'s shift-remove + insert).
    public mutating func upsertObject(
        at path: [String],
        managedKeys: [String],
        values: [(String, OrderedJSON)]
    ) throws(JSONConfigError) {
        guard !path.isEmpty else { throw .emptyPath }
        var entry: OrderedJSONObject
        switch value(at: path) {
        case .none: entry = OrderedJSONObject()
        case .object(let existing): entry = existing
        case .some: throw .notAnObject(path: path)
        }
        for key in managedKeys { entry.removeValue(forKey: key) }
        for (key, value) in values { entry[key] = value }
        try set(.object(entry), at: path)
    }

    public func rendered() -> String {
        OrderedJSON.object(root).rendered() + "\n"
    }

    public func renderedData() -> Data {
        Data(rendered().utf8)
    }

    private static func update(
        _ object: inout OrderedJSONObject,
        path: ArraySlice<String>,
        fullPath: [String],
        create: Bool,
        _ body: (inout OrderedJSONObject, String) -> Void
    ) throws(JSONConfigError) {
        let key = path[path.startIndex]
        if path.count == 1 {
            body(&object, key)
            return
        }
        var child: OrderedJSONObject
        switch object[key] {
        case .none:
            guard create else { return }
            child = OrderedJSONObject()
        case .object(let existing):
            child = existing
        case .some:
            throw .notAnObject(path: Array(fullPath[..<(path.startIndex + 1)]))
        }
        try update(&child, path: path.dropFirst(), fullPath: fullPath, create: create, body)
        object[key] = .object(child)
    }
}
