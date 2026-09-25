import Foundation

/// What a pane shows (upstream `PaneKind`). Terminal panes hold sub-tabs; every other kind shows one
/// file or page and has no tabs. Stored as `{ "kind": …, "path"/"url": … }`.
public enum PaneContent: Hashable, Sendable {
    case terminal
    /// A Markdown file, rendered and reloaded when it changes.
    case markdown(path: String)
    case image(path: String)
    case video(path: String)
    /// `git diff` of the project, or of one file when `path` is set; `staged` shows the index
    /// (`--staged`) instead of the working tree.
    case diff(path: String?, staged: Bool)
    case web(url: String, options: WebPaneOptions)
    /// The project repository's Graphify code graph (upstream `graphify` pane, P5-23).
    case graphify
    /// The orchestrator board: planners, runs and workers (upstream `orchestrator` pane, P6-13).
    case orchestrator

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case terminal, markdown, image, video, diff, web, graphify, orchestrator
    }

    public var kind: Kind {
        switch self {
        case .terminal: .terminal
        case .markdown: .markdown
        case .image: .image
        case .video: .video
        case .diff: .diff
        case .web: .web
        case .graphify: .graphify
        case .orchestrator: .orchestrator
        }
    }

    public var isTerminal: Bool { self == .terminal }

    /// The file this pane shows, for file-backed kinds.
    public var filePath: String? {
        switch self {
        case .markdown(let path), .image(let path), .video(let path): path
        default: nil
        }
    }

    /// The pane for a file, by extension (upstream `classifyPaneKind` in `terminalFactory.ts`); a
    /// trailing `:line[:column]` (as agents print paths) is dropped. nil for any other file, which
    /// upstream opens as a plain `file` pane the native app does not have yet.
    public static func forFile(_ rawPath: String) -> PaneContent? {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "avi", "mkv", "webm", "ogv": return .video(path: path)
        case "png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "ico", "svg": return .image(path: path)
        case "md", "markdown", "mdx": return .markdown(path: path)
        default: return nil
        }
    }
}

extension PaneContent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path, url, staged, options }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .terminal: self = .terminal
        case .markdown: self = .markdown(path: path ?? "")
        case .image: self = .image(path: path ?? "")
        case .video: self = .video(path: path ?? "")
        case .diff: self = .diff(path: path, staged: try container.decodeIfPresent(Bool.self, forKey: .staged) ?? false)
        case .web:
            self = .web(url: try container.decodeIfPresent(String.self, forKey: .url) ?? "",
                        options: try container.decodeIfPresent(WebPaneOptions.self, forKey: .options) ?? WebPaneOptions())
        case .graphify: self = .graphify
        case .orchestrator: self = .orchestrator
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .terminal, .graphify, .orchestrator: break
        case .markdown(let path), .image(let path), .video(let path):
            try container.encode(path, forKey: .path)
        case .diff(let path, let staged):
            try container.encodeIfPresent(path, forKey: .path)
            if staged { try container.encode(true, forKey: .staged) }
        case .web(let url, let options):
            try container.encode(url, forKey: .url)
            if options != WebPaneOptions() { try container.encode(options, forKey: .options) }
        }
    }
}
