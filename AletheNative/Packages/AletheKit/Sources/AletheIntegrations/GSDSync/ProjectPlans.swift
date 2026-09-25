import Foundation

/// A saved plan under `<repo>/.alethe/plans/` (upstream `PlanItem`).
public struct ProjectPlan: Hashable, Sendable, Identifiable {
    /// The file name without its extension.
    public var name: String
    public var projectID: String
    /// Set when the plan sits under `.alethe/plans/<terminal id>/`.
    public var terminalID: String?
    /// The first `# ` heading, else the file name.
    public var title: String
    public var fileURL: URL
    /// Relative to the repository, with `/` separators.
    public var relativePath: String
    public var createdAt: Date
    public var modifiedAt: Date

    public var id: URL { fileURL }
}

/// Upstream `list_project_plans`. Runs synchronously; call it off the main thread.
public enum ProjectPlans {
    public static func folder(of root: URL) -> URL {
        root.appending(path: ".alethe/plans", directoryHint: .isDirectory)
    }

    /// Every `.md`/`.markdown` file under `.alethe/plans/`, newest first; empty without the folder.
    public static func list(root: URL, projectID: String) -> [ProjectPlan] {
        let plansFolder = folder(of: root).standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: plansFolder, includingPropertiesForKeys: keys) else { return [] }
        let rootPath = root.standardizedFileURL.path + "/"
        let plansPath = plansFolder.path + "/"
        var plans: [ProjectPlan] = []
        for case let url as URL in enumerator {
            guard ["md", "markdown"].contains(url.pathExtension),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let file = url.standardizedFileURL
            let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let name = file.deletingPathExtension().lastPathComponent
            let inside = file.path.hasPrefix(plansPath) ? String(file.path.dropFirst(plansPath.count)) : file.lastPathComponent
            let segments = inside.split(separator: "/")
            plans.append(ProjectPlan(
                name: name,
                projectID: projectID,
                terminalID: segments.count > 1 ? String(segments[0]) : nil,
                title: title(of: file) ?? name,
                fileURL: file,
                relativePath: file.path.hasPrefix(rootPath) ? String(file.path.dropFirst(rootPath.count)) : file.path,
                createdAt: values.creationDate ?? modified,
                modifiedAt: modified
            ))
        }
        return plans.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// The first non-empty `# ` heading (upstream `extract_plan_title`).
    static func title(of url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !heading.isEmpty { return heading }
        }
        return nil
    }
}
