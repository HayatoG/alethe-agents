import Foundation

/// What can install agent CLIs on this Mac (upstream `InstallToolchain`, with Homebrew in place of
/// WinGet, Scoop and Chocolatey).
public struct InstallToolchain: Equatable, Sendable {
    public var node: String?
    public var npm: Bool
    public var brew: Bool

    public init(node: String? = nil, npm: Bool = false, brew: Bool = false) {
        self.node = node
        self.npm = npm
        self.brew = brew
    }

    public enum Requirement: Sendable { case npm, brew }

    func has(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .npm: npm
        case .brew: brew
        }
    }
}

/// One way to install (or remove) an agent CLI (upstream `InstallMethod`).
public struct InstallMethod: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        /// The vendor's own install script.
        case native, brew, npm
    }

    public var kind: Kind
    /// A fixed literal handed to the login shell; never built from user input.
    public var command: String
    public var requires: InstallToolchain.Requirement?
    /// CLI that proves the run worked; nil means the agent's own.
    public var verifyCommand: String?
    /// The run worked when the CLI is gone (uninstall).
    public var verifyAbsent: Bool = false

    public var id: String { "\(kind.rawValue):\(command)" }
}

/// Install commands per agent, macOS edition of upstream `AGENT_INSTALL_CATALOG`. Each command is
/// the one the vendor documents for macOS (checked 2026-09-24).
public enum AgentInstallCatalog {
    public struct Entry: Sendable {
        public var docsURL: URL
        public var methods: [InstallMethod]
    }

    private static func native(_ command: String) -> InstallMethod { InstallMethod(kind: .native, command: command) }
    private static func brew(_ command: String) -> InstallMethod { InstallMethod(kind: .brew, command: command, requires: .brew) }
    private static func npm(_ command: String) -> InstallMethod { InstallMethod(kind: .npm, command: command, requires: .npm) }

    public static let entries: [AgentKind: Entry] = [
        .claude: Entry(docsURL: URL(string: "https://code.claude.com/docs/en/setup")!, methods: [
            native("curl -fsSL https://claude.ai/install.sh | bash"),
            brew("brew install --cask claude-code"),
            npm("npm install -g @anthropic-ai/claude-code"),
        ]),
        .codex: Entry(docsURL: URL(string: "https://github.com/openai/codex")!, methods: [
            native("curl -fsSL https://chatgpt.com/codex/install.sh | sh"),
            brew("brew install --cask codex"),
            npm("npm install -g @openai/codex"),
        ]),
        .copilot: Entry(docsURL: URL(string: "https://docs.github.com/en/copilot/how-tos/copilot-cli/cli-getting-started")!, methods: [
            brew("brew install --cask copilot-cli"),
            npm("npm install -g @github/copilot"),
        ]),
        .cursor: Entry(docsURL: URL(string: "https://cursor.com/docs/cli/installation")!, methods: [
            native("curl https://cursor.com/install -fsS | bash"),
        ]),
        .antigravity: Entry(docsURL: URL(string: "https://antigravity.google/docs/cli/install")!, methods: [
            native("curl -fsSL https://antigravity.google/cli/install.sh | bash"),
        ]),
        .opencode: Entry(docsURL: URL(string: "https://opencode.ai/docs/")!, methods: [
            native("curl -fsSL https://opencode.ai/install | bash"),
            brew("brew install anomalyco/tap/opencode"),
            npm("npm install -g opencode-ai"),
        ]),
        .mimo: Entry(docsURL: URL(string: "https://github.com/XiaomiMiMo/MiMo-Code")!, methods: [
            native("curl -fsSL https://mimo.xiaomi.com/install | bash"),
            npm("npm install -g @mimo-ai/cli"),
        ]),
        .freebuff: Entry(docsURL: URL(string: "https://freebuff.com")!, methods: [
            npm("npm install -g freebuff"),
        ]),
        .kiro: Entry(docsURL: URL(string: "https://kiro.dev/cli/")!, methods: [
            native("curl -fsSL https://cli.kiro.dev/install | bash"),
        ]),
    ]

    /// Methods that work on this Mac, best first (native, Homebrew, npm; upstream `installMethodsFor`).
    public static func methods(for kind: AgentKind, toolchain: InstallToolchain?) -> [InstallMethod] {
        (entries[kind]?.methods ?? [])
            .filter { method in method.requires.map { toolchain?.has($0) ?? false } ?? true }
            .sorted { InstallMethod.Kind.allCases.firstIndex(of: $0.kind)! < InstallMethod.Kind.allCases.firstIndex(of: $1.kind)! }
    }

    /// How the agent can be removed here (upstream `uninstallMethodsFor`): package-manager installs
    /// only; install scripts document no uninstall, and guessing would delete the wrong thing.
    public static func uninstallMethods(for kind: AgentKind, toolchain: InstallToolchain?) -> [InstallMethod] {
        methods(for: kind, toolchain: toolchain).compactMap { method in
            let command: String
            switch method.kind {
            case .npm:
                guard let package = method.command.split(separator: " ").last else { return nil }
                command = "npm uninstall -g \(package)"
            case .brew:
                command = method.command.replacingOccurrences(of: "brew install", with: "brew uninstall")
            case .native:
                return nil
            }
            var uninstall = method
            uninstall.command = command
            uninstall.verifyAbsent = true
            return uninstall
        }
    }

    /// The agent has installers, but every one needs npm and npm is missing (upstream
    /// `needsNodeToolchain`).
    public static func needsNode(_ kind: AgentKind, toolchain: InstallToolchain?) -> Bool {
        guard let entry = entries[kind], !entry.methods.isEmpty else { return false }
        return methods(for: kind, toolchain: toolchain).isEmpty && entry.methods.contains { $0.requires == .npm }
    }

    /// Node through Homebrew when it is there; otherwise the download page.
    public static func nodeMethods(toolchain: InstallToolchain?) -> [InstallMethod] {
        toolchain?.brew == true ? [InstallMethod(kind: .brew, command: "brew install node", requires: .brew, verifyCommand: "npm")] : []
    }

    public static let nodeDownloadURL = URL(string: "https://nodejs.org/en/download")!

    /// npm package of an agent with an npm installer (upstream `npmPackageFor`).
    public static func npmPackage(for kind: AgentKind) -> String? {
        entries[kind]?.methods.first { $0.kind == .npm }.flatMap { $0.command.split(separator: " ").last.map(String.init) }
    }

    /// Agents not on npm whose GitHub releases track the CLI (upstream `GITHUB_RELEASE_REPO`).
    public static let githubReleaseRepos: [AgentKind: String] = [.antigravity: "google-antigravity/antigravity-cli"]

    /// The command line run for an install: the login shell, so the user's PATH (Homebrew, nvm…) is
    /// in place, exactly as they would type it.
    public static func shellArguments(for method: InstallMethod) -> [String] { ["-l", "-c", method.command] }
}

public enum AgentVersions {
    /// True when `latest` is a higher release than `installed`; prerelease suffixes ignored
    /// (upstream `isOutdated`).
    public static func isOutdated(_ installed: String, latest: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            var trimmed = Substring(version)
            if trimmed.hasPrefix("v") { trimmed = trimmed.dropFirst() }
            return (trimmed.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
        }
        let current = parts(installed), next = parts(latest)
        for index in 0..<max(current.count, next.count) {
            let a = index < current.count ? current[index] : 0
            let b = index < next.count ? next[index] : 0
            if a != b { return b > a }
        }
        return false
    }

    /// Latest published version from npm or GitHub releases; nil on any failure (an update hint is
    /// never worth an error).
    public static func latest(for kind: AgentKind, session: URLSession = .shared) async -> String? {
        if let package = AgentInstallCatalog.npmPackage(for: kind),
           let url = URL(string: "https://registry.npmjs.org/\(package)/latest") {
            return await json(url, session: session)?["version"] as? String
        }
        if let repo = AgentInstallCatalog.githubReleaseRepos[kind],
           let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest"),
           let tag = await json(url, session: session)?["tag_name"] as? String {
            return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }
        return nil
    }

    private static func json(_ url: URL, session: URLSession) async -> [String: Any]? {
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

public enum InstallLog {
    public static let maxCharacters = 12_000

    /// Installer output without escape sequences or control characters, trimmed to its tail
    /// (upstream `stripInstallLogAnsi`, `trimInstallLog`).
    public static func clean(_ text: String) -> String {
        let pattern = #"\u{1B}\[[0-9;?]*[ -/]*[@-~]|\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)|[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}]"#
        let stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return stripped.count > maxCharacters ? String(stripped.suffix(maxCharacters)) : stripped
    }
}
