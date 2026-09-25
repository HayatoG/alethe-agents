import Foundation

/// A planning step a human confirms by hand, recorded by the plugin's `gsd_record_step` tool into
/// `.planning/procedure.json` (upstream `ProcedureStep`).
public struct GSDProcedureStep: Codable, Hashable, Sendable {
    public var description: String
    public var category: String

    public init(description: String, category: String) {
        self.description = description
        self.category = category
    }
}

/// The OpenCode child session the plugin runs to keep `.planning/` in sync (upstream
/// `GsdChildState`): its id, whether it is working, and the last error it reported.
public struct GSDChildState: Hashable, Sendable {
    public var sessionID: String?
    public var busy: Bool
    public var error: String?

    public init(sessionID: String? = nil, busy: Bool = false, error: String? = nil) {
        self.sessionID = sessionID
        self.busy = busy
        self.error = error
    }
}

/// What a worktree's `.planning/` folder says about its task (upstream `PlanningStatus`).
public struct PlanningStatus: Hashable, Sendable {
    public var hasPlanning: Bool
    public var reportedComplete: Bool
    public var progress: Int?
    public var roadmapPendingCount: Int?
    public var roadmapTotalCount: Int?
    /// `plan.md`, trimmed; the step-by-step plan the child session writes.
    public var notes: String?

    public init(hasPlanning: Bool = false, reportedComplete: Bool = false, progress: Int? = nil,
                roadmapPendingCount: Int? = nil, roadmapTotalCount: Int? = nil, notes: String? = nil) {
        self.hasPlanning = hasPlanning
        self.reportedComplete = reportedComplete
        self.progress = progress
        self.roadmapPendingCount = roadmapPendingCount
        self.roadmapTotalCount = roadmapTotalCount
        self.notes = notes
    }
}

/// A markdown checklist item (`- [ ] text` / `- [x] text`).
public struct RoadmapItem: Hashable, Sendable {
    public var checked: Bool
    public var text: String
}

/// Reads the `.planning/` folder the GSD plugin maintains (upstream `planning_gate.rs`). Every
/// method does file I/O synchronously; call it off the main thread.
public enum PlanningGate {
    public static let folderName = ".planning"
    static let childSessionFile = ".gsd-child-session"
    static let childBusyFile = ".gsd-child-busy"
    static let childErrorFile = ".gsd-child-error"
    static let procedureFile = "procedure.json"

    /// The checkout that contains `path`: the nearest folder holding a `.git` entry (a folder in a
    /// main checkout, a file in a linked worktree), like `git rev-parse --show-toplevel` without
    /// spawning git. nil outside a repository.
    public static func repositoryRoot(containing path: URL) -> URL? {
        var current = path.standardizedFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        while true {
            if fileManager.fileExists(atPath: current.appending(path: ".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    public static func planningFolder(of root: URL) -> URL {
        root.appending(path: folderName, directoryHint: .isDirectory)
    }

    // MARK: Status

    /// Upstream `compute_planning_status`. `status.md`'s `Status:` wins over its `Progress:`, so a
    /// stale `In Progress` with a forgotten `100%` is not read as complete; without `status.md`, a
    /// fully checked `task.md` is.
    public static func status(of root: URL) -> PlanningStatus {
        let folder = planningFolder(of: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return PlanningStatus()
        }
        let statusText = read(folder, "status.md")
        let taskText = read(folder, "task.md")
        let planText = read(folder, "plan.md")

        var pending: Int?
        var total: Int?
        if let taskText, !isBlank(taskText) {
            let items = roadmapItems(taskText)
            total = items.count
            pending = items.filter { !$0.checked }.count
        }
        let notes = planText.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }

        guard let statusText, !isBlank(statusText) else {
            return PlanningStatus(
                hasPlanning: true,
                reportedComplete: (total ?? 0) > 0 && pending == 0,
                roadmapPendingCount: pending,
                roadmapTotalCount: total,
                notes: notes
            )
        }
        let (status, progress) = parseStatus(statusText)
        let complete = status.map(isCompleteStatus) ?? (progress == 100)
        return PlanningStatus(
            hasPlanning: true,
            reportedComplete: complete,
            progress: progress,
            roadmapPendingCount: pending,
            roadmapTotalCount: total,
            notes: notes
        )
    }

    /// `Status: <value>` (lowercased) and `Progress: <pct>%` lines (upstream `parse_status_md`).
    static func parseStatus(_ content: String) -> (status: String?, progress: Int?) {
        var status: String?
        var progress: Int?
        for line in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            switch key {
            case "status": status = value.lowercased()
            case "progress":
                var number = Substring(value)
                while number.hasSuffix("%") { number = number.dropLast() }
                // Upstream parses a `u8`: out-of-range values are no progress.
                progress = UInt8(number.trimmingCharacters(in: .whitespaces)).map(Int.init)
            default: break
            }
        }
        return (status, progress)
    }

    static func isCompleteStatus(_ status: String) -> Bool {
        ["completed", "complete", "done"].contains(status)
    }

    /// Upstream `parse_roadmap_items`: leading `-`/`*` bullets dropped, then `[<mark>]`; any mark
    /// but a space counts as checked.
    public static func roadmapItems(_ content: String) -> [RoadmapItem] {
        content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { line in
            let rest: Substring = line.drop(while: \.isWhitespace).drop(while: { $0 == "-" }).drop(while: { $0 == "*" })
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            let scalars = Array(trimmed.unicodeScalars)
            guard scalars.count >= 3, scalars[0] == "[", scalars[1].isASCII, scalars[2] == "]" else { return nil }
            let text = String(String.UnicodeScalarView(scalars[3...])).trimmingCharacters(in: .whitespaces)
            return RoadmapItem(checked: scalars[1] != " ", text: text)
        }
    }

    // MARK: Child session

    /// The child session id, trimmed; nil when missing or empty.
    public static func childSessionID(of root: URL) -> String? {
        nonEmpty(read(planningFolder(of: root), childSessionFile))
    }

    public static func childIsBusy(of root: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let path = planningFolder(of: root).appending(path: childBusyFile).path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// The child's last error, consumed: the file is removed once read, so each error is shown once
    /// (upstream `read_gsd_child_error`).
    public static func takeChildError(of root: URL) -> String? {
        let file = planningFolder(of: root).appending(path: childErrorFile)
        guard let error = nonEmpty(try? String(contentsOf: file, encoding: .utf8)) else { return nil }
        try? FileManager.default.removeItem(at: file)
        return error
    }

    /// All three sentinels in one read (upstream `read_gsd_child_state`); the error is consumed only
    /// while a child session exists.
    public static func childState(of root: URL) -> GSDChildState {
        let sessionID = childSessionID(of: root)
        return GSDChildState(
            sessionID: sessionID,
            busy: childIsBusy(of: root),
            error: sessionID == nil ? nil : takeChildError(of: root)
        )
    }

    /// The steps in `procedure.json`; empty when it is missing or not a list of steps.
    public static func procedure(of root: URL) -> [GSDProcedureStep] {
        guard let data = FileManager.default.contents(atPath: planningFolder(of: root).appending(path: procedureFile).path),
              let steps = try? JSONDecoder().decode([GSDProcedureStep].self, from: data) else { return [] }
        return steps
    }

    // MARK: Helpers

    private static func read(_ folder: URL, _ name: String) -> String? {
        try? String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
