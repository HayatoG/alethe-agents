import Foundation

/// Models an agent can run, for the New Terminal model picker (upstream `discover_provider_models`).
/// Only real sources: the CLI's own `models` listing where it has one, and Claude Code's documented
/// aliases. Upstream falls back to fixed lists that name retired models; those are left out, and any
/// other id can be typed.
public enum ModelDiscovery {
    /// The flag that picks a model, for agents that document one.
    public static func modelFlag(for kind: AgentKind) -> String? {
        switch kind {
        case .claude, .codex, .opencode, .cursor, .copilot: "--model"
        default: nil
        }
    }

    /// Agents whose CLI lists its models with `models` (upstream runs it for each).
    public static func listsModels(_ kind: AgentKind) -> Bool {
        kind == .cursor || kind == .opencode || kind == .antigravity
    }

    /// Claude Code's documented model aliases.
    public static let claudeAliases = ["sonnet", "opus", "haiku", "opusplan"]

    /// A line's first word when it looks like a model id, not CLI prose (upstream `is_valid_model_id`).
    public static func isValidModelID(_ id: String) -> Bool {
        let lower = id.lowercased()
        let prose = ["usage", "could", "error", "failed", "let", "flags", "available"]
        return id.count >= 3 && !id.hasPrefix("-") && !id.hasPrefix("#") && !id.contains(" ")
            && !prose.contains { lower.hasPrefix($0) }
    }

    /// Model ids from a `models` listing: each line's first word, valid ones only, first seen kept.
    public static func parse(_ output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return isValidModelID(id) && seen.insert(id).inserted ? id : nil
        }
    }

    /// Choices for an agent (empty when it has no model flag or nothing is found).
    public static func discover(_ kind: AgentKind, executable: String?) async -> [String] {
        guard modelFlag(for: kind) != nil || listsModels(kind) else { return [] }
        if kind == .claude { return claudeAliases }
        guard listsModels(kind), let executable,
              let output = await CLIOutput.run(executable, ["models"], timeout: .seconds(8)) else { return [] }
        return parse(output)
    }

    /// Extra arguments with `model` chosen (replacing any model already there); an empty model
    /// leaves the agent's default.
    public static func arguments(_ base: [String], model: String, for kind: AgentKind) -> [String] {
        guard let flag = modelFlag(for: kind) else { return base }
        var clean: [String] = []
        var index = 0
        while index < base.count {
            if base[index] == flag || base[index] == "-m" { index += 2; continue }
            if base[index].hasPrefix(flag + "=") { index += 1; continue }
            clean.append(base[index])
            index += 1
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? clean : clean + [flag, trimmed]
    }
}
