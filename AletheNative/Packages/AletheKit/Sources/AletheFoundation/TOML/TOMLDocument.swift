import Foundation

public enum TOMLError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The source is not valid TOML. `reason` is a fixed phrase that never quotes the file.
    case malformed(line: Int, column: Int, reason: String)
    /// The table or key to edit does not exist.
    case notFound
    /// The path runs through a key that holds a non-table value.
    case conflict
    /// The path runs through an array of tables (`[[…]]`), which the editor does not change.
    case unsupportedLayout
    /// The edit did not produce the expected document; nothing was changed.
    case invalidEdit

    public var description: String {
        switch self {
        case .malformed(let line, let column, let reason): "unparsable TOML at line \(line), column \(column): \(reason)"
        case .notFound: "not found"
        case .conflict: "the key path runs through a value that is not a table"
        case .unsupportedLayout: "the key path runs through an array of tables"
        case .invalidEdit: "the edit did not produce a valid document"
        }
    }
}

/// A TOML file that can be edited one table or key at a time while every other byte — comments,
/// blank lines, key order, spacing, quoting — stays as it was.
///
/// Edits splice the source: an unchanged key keeps its line, a changed scalar keeps its key,
/// spacing and trailing comment, and a table keeps the container it was written in (a
/// `[section]` or an `{ inline }` table). Each edit re-reads its result and checks it before
/// taking it, so a failed edit throws and leaves the document untouched.
public struct TOMLDocument: Sendable, Equatable, CustomStringConvertible {
    public private(set) var text: String
    public private(set) var root: TOMLTable
    private var bytes: [UInt8]
    private var index: TOMLIndex

    public init(parsing text: String) throws {
        let bytes = Array(text.utf8)
        do {
            index = try TOMLParser.parse(bytes)
        } catch let error as TOMLSyntaxError {
            let (line, column) = Self.position(of: error.offset, in: bytes)
            throw TOMLError.malformed(line: line, column: column, reason: error.reason)
        }
        self.bytes = bytes
        self.text = text
        root = index.root
    }

    private init(bytes: [UInt8], index: TOMLIndex) {
        self.bytes = bytes
        self.index = index
        text = String(decoding: bytes, as: UTF8.self)
        root = index.root
    }

    public var description: String { text }

    public static func == (lhs: TOMLDocument, rhs: TOMLDocument) -> Bool {
        lhs.bytes == rhs.bytes
    }

    private static func position(of offset: Int, in bytes: [UInt8]) -> (line: Int, column: Int) {
        let end = min(max(offset, 0), bytes.count)
        var line = 1
        var lineStart = 0
        for position in 0..<end where bytes[position] == 0x0A {
            line += 1
            lineStart = position + 1
        }
        return (line, end - lineStart + 1)
    }

    // MARK: Reading

    /// The value at a key path; the empty path is the root table.
    public func value(at path: [String]) -> TOMLValue? {
        root.value(at: path)
    }

    public func table(at path: [String]) -> TOMLTable? {
        value(at: path)?.tableValue
    }

    // MARK: Editing

    /// Makes the table at `path` equal to `table`, creating it when missing. Keys and subtables
    /// whose value does not change keep their bytes; new keys go after the table's last key and
    /// new tables after the last table under the same parent.
    public mutating func upsertTable(_ table: TOMLTable, at path: [String]) throws {
        guard !path.isEmpty else { throw TOMLError.conflict }
        try checkPath(path)
        var edit = TOMLEdit(bytes: bytes, newline: index.newline)
        try planUpsert(table, at: path, &edit)
        try commit(edit) { $0.table(at: path) == table }
    }

    /// Removes a table with its subtables (`[a.b]` takes `[a.b.env]` with it) and the comment
    /// lines directly above its header.
    public mutating func removeTable(at path: [String]) throws {
        guard !path.isEmpty, table(at: path) != nil else { throw TOMLError.notFound }
        try checkPath(path)
        var edit = TOMLEdit(bytes: bytes, newline: index.newline)
        try planRemove(path, &edit)
        try commit(edit) { $0.value(at: path) == nil }
    }

    /// Sets one key of an existing table (the root table by default).
    public mutating func setValue(_ value: TOMLValue, forKey key: String, inTableAt path: [String] = []) throws {
        guard var table = table(at: path) else { throw TOMLError.notFound }
        try checkPath(path + [key])
        table[key] = value
        var edit = TOMLEdit(bytes: bytes, newline: index.newline)
        if path.isEmpty {
            try planMerge(table, into: root, at: [], &edit)
        } else {
            try planUpsert(table, at: path, &edit)
        }
        try commit(edit) { $0.value(at: path + [key]) == value }
    }

    /// Removes one key of a table (the root table by default).
    public mutating func removeValue(forKey key: String, inTableAt path: [String] = []) throws {
        guard table(at: path)?[key] != nil else { throw TOMLError.notFound }
        let full = path + [key]
        try checkPath(full)
        var edit = TOMLEdit(bytes: bytes, newline: index.newline)
        try planRemove(full, &edit)
        try commit(edit) { $0.value(at: full) == nil }
    }

    private func checkPath(_ path: [String]) throws {
        var current = root
        for (position, key) in path.enumerated() {
            guard let next = current[key] else { return }
            let isLast = position == path.count - 1
            switch next {
            case .table(let table):
                current = table
            case .array(let items):
                let holdsTables = items.contains { $0.tableValue?.style == .section }
                if isLast && !holdsTables { return }
                throw TOMLError.unsupportedLayout
            default:
                if isLast { return }
                throw TOMLError.conflict
            }
        }
    }

    private mutating func commit(_ edit: TOMLEdit, verify: (TOMLDocument) -> Bool) throws {
        if edit.isEmpty {
            guard verify(self) else { throw TOMLError.invalidEdit }
            return
        }
        let edited = try edit.apply()
        guard let editedIndex = try? TOMLParser.parse(edited) else { throw TOMLError.invalidEdit }
        let next = TOMLDocument(bytes: edited, index: editedIndex)
        guard verify(next) else { throw TOMLError.invalidEdit }
        self = next
    }

    // MARK: Planning

    private struct StatementRef {
        let section: Int
        let statement: Int
        let fullPath: [String]
    }

    private var newline: String { index.newline }

    private func statement(_ ref: StatementRef) -> TOMLIndex.Statement {
        index.sections[ref.section].statements[ref.statement]
    }

    /// The `[path]` section (the root section for the empty path).
    private func headerSection(at path: [String]) -> Int? {
        if path.isEmpty { return 0 }
        return index.sections.indices.first { position in
            let section = index.sections[position]
            return !section.isRoot && !section.isArray && !section.isArrayScoped && section.path == path
        }
    }

    /// Every section below `path`, arrays of tables included.
    private func descendants(of path: [String]) -> [Int] {
        index.sections.indices.filter { position in
            let section = index.sections[position]
            return !section.isRoot && section.path.count > path.count && section.path.starts(with: path)
        }
    }

    /// Key/value lines of the sections that are `path` or one of its ancestors.
    private func statementRefs(along path: [String]) -> [StatementRef] {
        var refs: [StatementRef] = []
        for (position, section) in index.sections.enumerated()
        where !section.isArray && !section.isArrayScoped && path.starts(with: section.path) {
            for (number, statement) in section.statements.enumerated() {
                refs.append(StatementRef(section: position, statement: number, fullPath: section.path + statement.key))
            }
        }
        return refs
    }

    /// The line whose value holds `path` (the key itself, or an inline table around it).
    private func covering(_ path: [String]) -> StatementRef? {
        statementRefs(along: path).first { path.starts(with: $0.fullPath) }
    }

    /// Dotted keys in ancestor sections that define something below `path` (`a.b.c = 1` in `[a]`).
    private func dottedKeys(under path: [String]) -> [StatementRef] {
        statementRefs(along: path).filter { ref in
            index.sections[ref.section].path.count < path.count && ref.fullPath.count > path.count
                && ref.fullPath.starts(with: path)
        }
    }

    /// Start of the comment lines directly above a header.
    private func attachedStart(_ offset: Int) -> Int {
        var start = offset
        while let line = index.trivia[start], line.kind == .comment { start = line.start }
        return start
    }

    /// A section with its attached comments and the one blank line separating it from what
    /// precedes it, so that removing a table added by `upsertTable` restores the original.
    private func sectionRange(_ position: Int) -> Range<Int> {
        let section = index.sections[position]
        let headerStart = section.header?.lowerBound ?? index.contentStart
        var start = attachedStart(headerStart)
        if let line = index.trivia[start], line.kind == .blank { start = line.start }
        return start..<section.bodyEnd
    }

    private func statementsEnd(_ position: Int) -> Int {
        let section = index.sections[position]
        return section.statements.last?.line.upperBound ?? section.header?.upperBound ?? index.contentStart
    }

    /// Where a new table goes: after the last section under its nearest existing ancestor,
    /// otherwise at the end of the file.
    private func placement(for path: [String]) -> Int {
        for length in stride(from: path.count - 1, through: 1, by: -1) {
            let prefix = Array(path.prefix(length))
            let ends = index.sections.filter { !$0.isRoot && $0.path.starts(with: prefix) }.map(\.bodyEnd)
            if let end = ends.max() { return end }
        }
        return bytes.count
    }

    private func leadingBlank(at offset: Int) -> String {
        offset > index.contentStart ? newline : ""
    }

    private static func isSectionLike(_ value: TOMLValue) -> Bool {
        switch value {
        case .table(let table): return table.style == .section
        case .array(let items): return !items.isEmpty && items.allSatisfy { $0.tableValue?.style == .section }
        default: return false
        }
    }

    private func keyLine(_ key: String, _ value: TOMLValue) -> String {
        TOMLRender.key(key) + " = " + TOMLRender.inline(value) + newline
    }

    private func sectionText(_ path: [String], _ table: TOMLTable, isArray: Bool = false) -> String {
        let header = TOMLRender.keyPath(path)
        var out = (isArray ? "[[" + header + "]]" : "[" + header + "]") + newline
        var nested: [String] = []
        for (key, value) in table.entries {
            if Self.isSectionLike(value) {
                nested.append(sectionTexts(path + [key], value))
            } else {
                out += keyLine(key, value)
            }
        }
        for text in nested { out += newline + text }
        return out
    }

    /// A section-like value as one `[table]` or a run of `[[array]]` elements.
    private func sectionTexts(_ path: [String], _ value: TOMLValue) -> String {
        switch value {
        case .table(let table):
            return sectionText(path, table)
        case .array(let items):
            return items.compactMap(\.tableValue).map { sectionText(path, $0, isArray: true) }
                .joined(separator: newline)
        default:
            return ""
        }
    }

    private func planUpsert(_ table: TOMLTable, at path: [String], _ edit: inout TOMLEdit) throws {
        if let cover = covering(path) {
            let line = statement(cover)
            let relative = path.dropFirst(cover.fullPath.count)
            var replacement = TOMLValue.table(table)
            if !relative.isEmpty {
                guard case .table(var host) = line.value,
                      host.setValue(.table(table), at: relative, intermediateStyle: .inline) else {
                    throw TOMLError.conflict
                }
                replacement = .table(host)
            }
            edit.replace(line.valueRange, with: TOMLRender.inline(replacement))
            return
        }
        guard let existing = root.value(at: path) else {
            planNewTable(table, at: path, &edit)
            return
        }
        guard case .table(let current) = existing else { throw TOMLError.conflict }
        try planMerge(table, into: current, at: path, &edit)
    }

    private func planNewTable(_ table: TOMLTable, at path: [String], _ edit: inout TOMLEdit) {
        if table.style == .inline, let key = path.last, let parent = headerSection(at: Array(path.dropLast())) {
            edit.insert(keyLine(key, .table(table)), at: statementsEnd(parent))
            return
        }
        let offset = placement(for: path)
        edit.insert(leadingBlank(at: offset) + sectionText(path, table), at: offset)
    }

    /// Edits the table at `path`, which is written as a `[path]` section, implied by
    /// `[path.child]` headers, or defined by dotted keys in an ancestor section.
    private func planMerge(_ table: TOMLTable, into current: TOMLTable, at path: [String],
                           _ edit: inout TOMLEdit) throws {
        let own = headerSection(at: path)
        var lines: [String: [StatementRef]] = [:]
        if let own {
            for (number, line) in index.sections[own].statements.enumerated() {
                lines[line.key[0], default: []].append(
                    StatementRef(section: own, statement: number, fullPath: path + line.key))
            }
        }
        for ref in dottedKeys(under: path) {
            lines[ref.fullPath[path.count], default: []].append(ref)
        }
        let subtree = descendants(of: path)
        var sections: [String: [Int]] = [:]
        for position in subtree {
            sections[index.sections[position].path[path.count], default: []].append(position)
        }

        var removed = Set<Int>()
        var keyLines = ""
        var newSections: [String] = []

        func drop(_ key: String, _ edit: inout TOMLEdit) {
            for ref in lines[key] ?? [] { edit.delete(statement(ref).line) }
            for position in sections[key] ?? [] {
                edit.delete(sectionRange(position))
                removed.insert(position)
            }
        }
        func add(_ key: String, _ value: TOMLValue) {
            if Self.isSectionLike(value) {
                newSections.append(sectionTexts(path + [key], value))
            } else {
                keyLines += keyLine(key, value)
            }
        }

        for key in current.keys where table[key] == nil {
            drop(key, &edit)
        }
        for (key, value) in table.entries {
            guard let old = current[key] else {
                add(key, value)
                continue
            }
            if old == value { continue }
            let refs = lines[key] ?? []
            let subsections = sections[key] ?? []
            if refs.isEmpty, !subsections.isEmpty, case .table(let newTable) = value, case .table(let oldTable) = old {
                try planMerge(newTable, into: oldTable, at: path + [key], &edit)
                continue
            }
            if subsections.isEmpty, refs.count == 1, let own, refs[0].section == own,
               refs[0].fullPath.count == path.count + 1 {
                edit.replace(statement(refs[0]).valueRange, with: TOMLRender.inline(value))
                continue
            }
            drop(key, &edit)
            add(key, value)
        }

        if !keyLines.isEmpty {
            if let own {
                edit.insert(keyLines, at: statementsEnd(own))
            } else {
                let header = "[" + TOMLRender.keyPath(path) + "]" + newline
                let remaining = subtree.filter { !removed.contains($0) }
                    .compactMap { index.sections[$0].header?.lowerBound }.min()
                if let remaining {
                    edit.insert(header + keyLines + newline, at: attachedStart(remaining))
                } else {
                    let offset = placement(for: path)
                    var text = leadingBlank(at: offset) + header + keyLines
                    for section in newSections { text += newline + section }
                    edit.insert(text, at: offset)
                    return
                }
            }
        }
        if !newSections.isEmpty {
            let ends = (own.map { [$0] } ?? []) + subtree
            let end = ends.map { index.sections[$0].bodyEnd }.max() ?? placement(for: path)
            for section in newSections { edit.insert(leadingBlank(at: end) + section, at: end) }
        }
    }

    private func planRemove(_ path: [String], _ edit: inout TOMLEdit) throws {
        if let cover = covering(path) {
            let line = statement(cover)
            if cover.fullPath.count == path.count {
                edit.delete(line.line)
                return
            }
            let relative = path.dropFirst(cover.fullPath.count)
            guard case .table(var host) = line.value, host.value(at: relative) != nil,
                  host.setValue(nil, at: relative) else { throw TOMLError.notFound }
            edit.replace(line.valueRange, with: TOMLRender.inline(.table(host)))
            return
        }
        guard root.value(at: path) != nil else { throw TOMLError.notFound }
        if let own = headerSection(at: path) { edit.delete(sectionRange(own)) }
        for position in descendants(of: path) { edit.delete(sectionRange(position)) }
        for ref in dottedKeys(under: path) { edit.delete(statement(ref).line) }
    }
}

/// Byte splices against one source, applied back to front.
struct TOMLEdit {
    private struct Change {
        let range: Range<Int>
        let text: String
        let order: Int
    }

    let bytes: [UInt8]
    let newline: String
    private var changes: [Change] = []
    private var endOfFileTerminated = false

    init(bytes: [UInt8], newline: String) {
        self.bytes = bytes
        self.newline = newline
    }

    var isEmpty: Bool { changes.isEmpty }

    mutating func delete(_ range: Range<Int>) {
        replace(range, with: "")
    }

    mutating func replace(_ range: Range<Int>, with text: String) {
        changes.append(Change(range: range, text: text, order: changes.count))
    }

    /// Inserts at an offset; text inserted after a last line without a newline gets one first.
    mutating func insert(_ text: String, at offset: Int) {
        var text = text
        if offset == bytes.count, offset > 0, bytes[offset - 1] != 0x0A, !endOfFileTerminated {
            text = newline + text
            endOfFileTerminated = true
        }
        changes.append(Change(range: offset..<offset, text: text, order: changes.count))
    }

    func apply() throws -> [UInt8] {
        var unique: [Change] = []
        for change in changes where !unique.contains(where: {
            !change.range.isEmpty && $0.range == change.range && $0.text == change.text
        }) {
            unique.append(change)
        }
        // Back to front; at one offset a removal goes before insertions, and later insertions
        // go first so the text ends up in the order it was planned.
        let ordered = unique.sorted { lhs, rhs in
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound > rhs.range.lowerBound }
            if lhs.range.isEmpty != rhs.range.isEmpty { return !lhs.range.isEmpty }
            return lhs.order > rhs.order
        }
        var result = bytes
        var floor = Int.max
        for change in ordered {
            guard change.range.upperBound <= floor else { throw TOMLError.invalidEdit }
            floor = change.range.lowerBound
            result.replaceSubrange(change.range, with: Array(change.text.utf8))
        }
        return result
    }
}
