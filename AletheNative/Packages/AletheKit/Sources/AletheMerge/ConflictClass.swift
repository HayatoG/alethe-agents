import Foundation

/// The kind of a conflicted path; each class carries its resolution strategy (upstream
/// `merge_analyzer.rs`, RFC-006). Raw values match upstream's camelCase serialization.
public enum ConflictClass: String, Sendable, Hashable, Codable, CaseIterable {
    case rust, typeScript, ui, cargo, package, json, config, asset, planning
    /// Ephemeral machine state (e.g. `.gsd-child-session`): an opaque value, not mergeable prose.
    case sentinel
    case graph, other

    /// Upstream's variant name; the order of `MergeAnalysis.classes` sorts by it.
    public var variantName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Classifies by path and extension. Lockfiles and manifests get their own class because the
    /// strategy differs from regular code (regenerate rather than hand-edit).
    public static func classify(_ path: String) -> ConflictClass {
        let lower = path.replacingOccurrences(of: "\\", with: "/").lowercased()
        let fileName = lower.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? lower

        // Sentinels come before the `.planning/` fallback: merging both values breaks the spawn.
        if [".gsd-child-session", ".gsd-child-busy", ".gsd-child-error"].contains(fileName) {
            return .sentinel
        }
        if lower.hasPrefix(".planning/") || lower.contains("/.planning/") { return .planning }
        if lower.hasPrefix("graphify-out/") || lower.contains("/graphify-out/") { return .graph }
        switch fileName {
        case "cargo.toml", "cargo.lock": return .cargo
        case "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml": return .package
        default: break
        }

        let ext = fileName.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        switch ext {
        case "rs": return .rust
        case "ts", "tsx", "js", "jsx", "mts", "cts": return .typeScript
        case "css", "scss", "less": return .ui
        case "json": return .json
        case "toml", "yml", "yaml", "ini", "conf", "env", "properties": return .config
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "ttf", "otf", "woff", "woff2", "mp3", "mp4", "bin":
            return .asset
        default: return .other
        }
    }

    /// Strategy text handed to the resolution agent as minimal context (verbatim from upstream so the
    /// classifier and the prompt never diverge).
    public var strategy: String {
        switch self {
        case .rust:
            "Rust code: preserve both intentions; after resolving, the code must compile (cargo check)."
        case .typeScript:
            "TypeScript/JS code: preserve both intentions; duplicate imports/exports are the common cause; tsc must pass."
        case .ui:
            "Styles: merge the rules from both branches; never invent new colors — use the existing theme tokens."
        case .cargo:
            "Cargo.toml/lock: merge the dependencies from both branches; on a Cargo.lock conflict, prefer regenerating (cargo update -p / cargo check) over hand-editing."
        case .package:
            "package.json/lockfile: merge the dependencies; on a lockfile conflict, prefer regenerating (npm install) over hand-editing."
        case .json:
            "JSON: the result must be valid JSON; merge the keys from both branches; watch out for commas."
        case .config:
            "Configuration: merge the entries; for duplicate keys with different values, understand each branch's intent before choosing."
        case .asset:
            "Binary/asset: there is no textual merge — pick the correct version (usually the newest) via git checkout --theirs/--ours."
        case .planning:
            "Planning (.planning/): preserve both branches' history; never discard tasks from either side."
        case .sentinel:
            "Ephemeral machine state from GSD Sync (session ID, busy/error flag) — this is NOT content to merge, it's a single-line opaque value. NEVER paste both values together nor leave any conflict marker (<<<<<<<, =======, >>>>>>>) in the file. Resolve by deleting the file entirely (it is recreated on its own on the next GSD Sync cycle) — never pick a 'middle ground' value."
        case .graph:
            "Graph (graphify-out/): don't resolve by hand — the graph is generated; pick either side and regenerate with Graphify afterward."
        case .other:
            "Preserve both intentions; if unsure, keep both snippets and flag it in the commit."
        }
    }
}
