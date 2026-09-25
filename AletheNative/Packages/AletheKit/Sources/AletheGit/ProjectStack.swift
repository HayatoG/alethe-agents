import Foundation

/// What kind of project a folder holds (upstream `project_detector.rs` `ProjectStack`). A backend
/// without a frontend is `cli`, as upstream reports it.
public enum ProjectStack: String, Codable, CaseIterable, Sendable {
    case web, cli, desktop, fullstack, unknown
}

/// The result of `ProjectStackDetector.detect(_:)` (upstream `StackDetection`).
public struct StackDetection: Codable, Equatable, Sendable {
    public var stack: ProjectStack
    public var hasFrontend: Bool
    public var hasBackend: Bool
    public var hasTauri: Bool
    /// Validation commands for the stack, in upstream's order.
    public var suggestedCommands: [String]

    public init(stack: ProjectStack, hasFrontend: Bool, hasBackend: Bool, hasTauri: Bool, suggestedCommands: [String]) {
        self.stack = stack
        self.hasFrontend = hasFrontend
        self.hasBackend = hasBackend
        self.hasTauri = hasTauri
        self.suggestedCommands = suggestedCommands
    }
}

/// Port of upstream `detect_project_stack`: looks only at well-known manifests at the folder's top
/// level, so it is cheap, but it still reads files; call it off the main thread.
public enum ProjectStackDetector {
    public enum Failure: Error, Equatable, Sendable {
        /// Upstream `repo_not_found`.
        case folderNotFound
    }

    static let frontendDependencies = ["react", "vue", "svelte", "next", "vite", "@angular/core"]

    public static func detect(_ root: URL) throws(Failure) -> StackDetection {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .folderNotFound
        }
        func has(_ name: String) -> Bool { isFile(root.appending(path: name)) }

        let hasTauri = has("tauri.conf.json") || has("src-tauri/tauri.conf.json")
        let hasFrontend = has("package.json") && packageHasFrontendSignal(root.appending(path: "package.json"))
        let hasPython = has("requirements.txt") || has("pyproject.toml")
        let hasBackend = hasPython || has("go.mod") || (has("Cargo.toml") && !hasTauri)

        let stack: ProjectStack = if hasTauri {
            .desktop
        } else if hasFrontend && hasBackend {
            .fullstack
        } else if hasFrontend {
            .web
        } else if hasBackend {
            .cli
        } else {
            .unknown
        }

        var commands: [String] = []
        switch stack {
        case .desktop:
            commands = ["npm run build", "cargo check --manifest-path src-tauri/Cargo.toml"]
        case .web:
            commands = ["npm run build"]
        case .fullstack:
            commands = ["npm run build"]
            if hasPython { commands.append("python -m py_compile .") }
            if has("Cargo.toml") { commands.append("cargo check") }
            if has("go.mod") { commands.append("go build ./...") }
        case .cli:
            if has("Cargo.toml") { commands.append("cargo check") }
            if has("go.mod") { commands.append("go build ./...") }
            if hasPython { commands.append("python -m py_compile .") }
        case .unknown:
            break
        }
        return StackDetection(stack: stack, hasFrontend: hasFrontend, hasBackend: hasBackend, hasTauri: hasTauri,
                              suggestedCommands: commands)
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// A `dev`/`build`/`start` script or a known frontend dependency; unreadable JSON is no signal.
    private static func packageHasFrontendSignal(_ file: URL) -> Bool {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let scripts = json["scripts"] as? [String: Any],
           scripts["dev"] != nil || scripts["build"] != nil || scripts["start"] != nil {
            return true
        }
        let dependencies = json["dependencies"] as? [String: Any] ?? [:]
        let devDependencies = json["devDependencies"] as? [String: Any] ?? [:]
        return frontendDependencies.contains { dependencies[$0] != nil || devDependencies[$0] != nil }
    }
}
