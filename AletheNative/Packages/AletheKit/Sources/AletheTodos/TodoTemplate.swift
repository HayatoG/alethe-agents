import Foundation

/// The external JSONC todo file (upstream `ensure_todo_template` in `src-tauri/src/filesystem.rs`).
public enum TodoTemplate {
    public static let fileName = "alethe-todo.template.jsonc"
    public static let schemaVersion = 1

    /// Upstream's template text.
    public static let defaultContent = """
    // Alethe Todo template

    // For now, the app stores Todo items in its local profile; this template documents
    // the structure expected by the importer/sync layer.
    {
      // Schema version for future migrations.
      "version": 1,

      // Global personal task list. Order in this array is the visible order.
      "todos": [
        {
          // Stable id. Any unique string is accepted.
          "id": "task-example-1",

          // Text shown in the Todo sidebar.
          "title": "Example task",

          // false = Active, true = Completed.
          "completed": false
        }
      ]
    }

    """

    public enum TemplateError: Error, Equatable {
        case emptyDirectory
        case notADirectory
        case invalidDocument(String)
    }

    /// Creates `directory` and the template inside it when missing; an existing file is never
    /// overwritten. Returns the template's URL.
    @discardableResult
    public static func ensure(in directory: URL, fileManager: FileManager = .default) throws -> URL {
        guard !directory.path.trimmingCharacters(in: .whitespaces).isEmpty else { throw TemplateError.emptyDirectory }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TemplateError.notADirectory
        }
        let url = directory.appending(path: fileName)
        if !fileManager.fileExists(atPath: url.path) {
            try Data(defaultContent.utf8).write(to: url, options: .atomic)
        }
        return url
    }

    /// `ensure` through a file-access service (the plugin's filesystem capability): an existing file
    /// is kept; a missing one is written with the default content. The writer creates the folder.
    @discardableResult
    public static func ensure(in directory: URL, using files: TodoFileAccess) async throws -> URL {
        guard !directory.path.trimmingCharacters(in: .whitespaces).isEmpty else { throw TemplateError.emptyDirectory }
        let url = directory.appending(path: fileName)
        do {
            _ = try await files.read(url)
        } catch where TodoFileAccess.isMissingFile(error) {
            try await files.write(Data(defaultContent.utf8), url)
        }
        return url
    }

    // MARK: Reading

    /// One entry of the file's `todos` array. Only `title` is required.
    struct Entry: Codable {
        var id: String?
        var title: String
        var completed: Bool?
        var tags: [String]?
        var projectId: String?
        var prUrl: String?
    }

    struct Document: Codable {
        var version: Int?
        var todos: [Entry]
    }

    /// Parses JSONC into todos, in file order. Entries with an empty title are skipped.
    public static func parse(_ data: Data, now: Date = Date()) throws -> [Todo] {
        let json = JSONC.strip(String(decoding: data, as: UTF8.self))
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(json.utf8))
        } catch {
            throw TemplateError.invalidDocument(String(describing: error))
        }
        var seen = Set<String>()
        var todos: [Todo] = []
        for entry in document.todos {
            let title = TodoRules.normalizeTitle(entry.title)
            guard !title.isEmpty else { continue }
            var id = entry.id?.trimmingCharacters(in: .whitespaces) ?? ""
            if id.isEmpty || seen.contains(id) { id = UUID().uuidString }
            seen.insert(id)
            todos.append(Todo(
                id: id,
                title: title,
                done: entry.completed ?? false,
                tags: TodoRules.normalizeTags(entry.tags ?? []),
                prURL: entry.prUrl.flatMap(URL.init(string:)),
                projectID: entry.projectId,
                order: todos.count,
                createdAt: now
            ))
        }
        return todos
    }

    // MARK: Writing

    /// Renders todos in the template's shape (JSON with a leading comment), readable by `parse`.
    public static func render(_ todos: [Todo]) throws -> Data {
        let document = Document(version: schemaVersion, todos: todos.map {
            Entry(
                id: $0.id,
                title: $0.title,
                completed: $0.done,
                tags: $0.tags.isEmpty ? nil : $0.tags,
                projectId: $0.projectID,
                prUrl: $0.prURL?.absoluteString
            )
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let body = String(decoding: try encoder.encode(document), as: UTF8.self)
        return Data("// Alethe Todo list. Order in \"todos\" is the visible order.\n\(body)\n".utf8)
    }
}

/// Reads and writes whole files. The Todos plugin builds it from its context's filesystem
/// capability, so every template access is checked against the manifest.
public struct TodoFileAccess: Sendable {
    public var read: @Sendable (URL) async throws -> Data
    public var write: @Sendable (Data, URL) async throws -> Void

    public init(read: @escaping @Sendable (URL) async throws -> Data, write: @escaping @Sendable (Data, URL) async throws -> Void) {
        self.read = read
        self.write = write
    }

    /// True for "no such file" errors from Foundation or POSIX.
    public static func isMissingFile(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileReadNoSuchFile || cocoa.code == .fileNoSuchFile { return true }
        if let posix = error as? POSIXError, posix.code == .ENOENT { return true }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT)
    }
}

/// JSON with comments: drops `//` and `/* */` comments and trailing commas, leaving strings intact.
public enum JSONC {
    public static func strip(_ source: String) -> String {
        let chars = Array(source.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
            if inString {
                output.append(char)
                if char == "\\", let next {
                    output.append(next)
                    index += 2
                    continue
                }
                if char == "\"" { inString = false }
                index += 1
            } else if char == "\"" {
                inString = true
                output.append(char)
                index += 1
            } else if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if char == "/", next == "*" {
                index += 2
                while index < chars.count, !(chars[index] == "*" && index + 1 < chars.count && chars[index + 1] == "/") {
                    index += 1
                }
                index += 2
            } else if char == "," {
                // A comma followed only by whitespace/comments before `}` or `]` is trailing.
                var lookahead = index + 1
                var trailing = false
                scan: while lookahead < chars.count {
                    let c = chars[lookahead]
                    let n: Unicode.Scalar? = lookahead + 1 < chars.count ? chars[lookahead + 1] : nil
                    switch c {
                    case " ", "\t", "\n", "\r":
                        lookahead += 1
                    case "/" where n == "/":
                        while lookahead < chars.count, chars[lookahead] != "\n" { lookahead += 1 }
                    case "/" where n == "*":
                        lookahead += 2
                        while lookahead < chars.count, !(chars[lookahead] == "*" && lookahead + 1 < chars.count && chars[lookahead + 1] == "/") {
                            lookahead += 1
                        }
                        lookahead += 2
                    case "}", "]":
                        trailing = true
                        break scan
                    default:
                        break scan
                    }
                }
                if !trailing { output.append(char) }
                index += 1
            } else {
                output.append(char)
                index += 1
            }
        }
        return String(output)
    }
}
