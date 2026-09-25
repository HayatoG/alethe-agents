import Foundation

/// A unified diff as rows a view can draw, unified or side by side (upstream `DiffPane` colors each
/// line; the split view is native).
public struct DiffDocument: Hashable, Sendable {
    public var files: [DiffFile]

    public init(files: [DiffFile]) {
        self.files = files
    }

    public var isEmpty: Bool { files.isEmpty }
}

public struct DiffFile: Hashable, Sendable, Identifiable {
    public var id: Int
    /// The path after the change (before it, for a deletion).
    public var path: String
    /// `diff --git`, `index`, `---`, `+++`, rename and mode lines.
    public var header: [String]
    public var hunks: [DiffHunk]
}

public struct DiffHunk: Hashable, Sendable {
    public var header: String
    public var lines: [DiffLine]
}

public struct DiffLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case context, added, removed, note }
    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
}

/// One row of the side-by-side view: the old line on the left, the new one on the right.
public struct DiffSplitRow: Hashable, Sendable {
    public var left: DiffLine?
    public var right: DiffLine?
}

public enum DiffParser {
    public static func parse(_ text: String) -> DiffDocument {
        var files: [DiffFile] = []
        var file: DiffFile?
        var hunk: DiffHunk?
        var old = 0, new = 0

        func closeHunk() {
            if let current = hunk { file?.hunks.append(current) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let current = file { files.append(current) }
            file = nil
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The final newline is not an empty context line.
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            if line.hasPrefix("diff --git ") {
                closeFile()
                file = DiffFile(id: files.count, path: gitPath(line), header: [line], hunks: [])
            } else if line.hasPrefix("@@"), file != nil {
                closeHunk()
                (old, new) = hunkStarts(line)
                hunk = DiffHunk(header: line, lines: [])
            } else if hunk != nil {
                if line.hasPrefix("+") {
                    hunk?.lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: new))
                    new += 1
                } else if line.hasPrefix("-") {
                    hunk?.lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: old, newNumber: nil))
                    old += 1
                } else if line.hasPrefix("\\") {
                    hunk?.lines.append(DiffLine(kind: .note, text: line, oldNumber: nil, newNumber: nil))
                } else if line.hasPrefix(" ") || line.isEmpty {
                    hunk?.lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: old, newNumber: new))
                    old += 1
                    new += 1
                }
            } else if file != nil {
                file?.header.append(line)
                if line.hasPrefix("+++ b/") { file?.path = String(line.dropFirst(6)) }
            }
        }
        closeFile()
        return DiffDocument(files: files)
    }

    /// Pairs removals with the additions that follow them; context lines sit on both sides.
    public static func split(_ hunk: DiffHunk) -> [DiffSplitRow] {
        var rows: [DiffSplitRow] = []
        var removed: [DiffLine] = [], added: [DiffLine] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(DiffSplitRow(left: index < removed.count ? removed[index] : nil,
                                         right: index < added.count ? added[index] : nil))
            }
            removed.removeAll()
            added.removeAll()
        }
        for line in hunk.lines {
            switch line.kind {
            case .removed: removed.append(line)
            case .added: added.append(line)
            case .context, .note:
                flush()
                rows.append(DiffSplitRow(left: line, right: line))
            }
        }
        flush()
        return rows
    }

    /// `@@ -12,7 +12,9 @@` → (12, 12).
    static func hunkStarts(_ header: String) -> (Int, Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 1 }
            return Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (start("-"), start("+"))
    }

    /// `diff --git a/x b/y` → `y`.
    static func gitPath(_ line: String) -> String {
        guard let range = line.range(of: " b/", options: .backwards) else { return line }
        return String(line[range.upperBound...])
    }

}

public enum GitDiffError: Error, Equatable, Sendable {
    case notARepository
    case tooLarge
    case binary
    case failed(String)
}

/// Runs `git diff` (upstream `git_diff` in `git_control.rs`, plus a whole-repository variant).
public enum GitDiff {
    /// Upstream refuses diffs over 2 MiB (they freeze the renderer).
    public static let maxBytes = 2 * 1024 * 1024

    public static func run(folder: String, path: String?, staged: Bool,
                           git: String = "/usr/bin/git") async -> Result<String, GitDiffError> {
        await Task.detached(priority: .userInitiated) {
            var arguments = ["-C", folder, "diff", "--no-color", "--no-ext-diff"]
            if staged { arguments.append("--staged") }
            if let path { arguments += ["--", path] }
            let process = Process()
            process.executableURL = URL(filePath: git)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_PAGER"] = "cat"
            environment["LC_ALL"] = "C"
            process.environment = environment
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
            // Read before waiting: a large diff fills the pipe and would block git forever.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if errorText.localizedCaseInsensitiveContains("not a git repository") { return .failure(.notARepository) }
                return .failure(.failed(errorText.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if data.count > maxBytes { return .failure(.tooLarge) }
            let text = String(decoding: data, as: UTF8.self)
            if text.contains("Binary files "), text.contains(" differ"), !text.contains("\n@@") {
                return .failure(.binary)
            }
            return .success(text)
        }.value
    }
}
