import Foundation

/// What a pane shows (upstream `PaneKind`). Terminal panes hold sub-tabs; every other kind shows one
/// file or page and has no tabs. Stored as `{ "kind": …, "path"/"url": … }`.
public enum PaneContent: Hashable, Sendable {
    case terminal
    /// A Markdown file, rendered and reloaded when it changes.
    case markdown(path: String)
    case image(path: String)
    case video(path: String)
    /// `git diff` of the project, or of one file when `path` is set.
    case diff(path: String?)
    case web(url: String)

    public enum Kind: String, Codable, CaseIterable, Sendable {
        case terminal, markdown, image, video, diff, web
    }

    public var kind: Kind {
        switch self {
        case .terminal: .terminal
        case .markdown: .markdown
        case .image: .image
        case .video: .video
        case .diff: .diff
        case .web: .web
        }
    }

    public var isTerminal: Bool { self == .terminal }
}

extension PaneContent: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path, url }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .terminal: self = .terminal
        case .markdown: self = .markdown(path: path ?? "")
        case .image: self = .image(path: path ?? "")
        case .video: self = .video(path: path ?? "")
        case .diff: self = .diff(path: path)
        case .web: self = .web(url: try container.decodeIfPresent(String.self, forKey: .url) ?? "")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .terminal: break
        case .markdown(let path), .image(let path), .video(let path):
            try container.encode(path, forKey: .path)
        case .diff(let path):
            try container.encodeIfPresent(path, forKey: .path)
        case .web(let url):
            try container.encode(url, forKey: .url)
        }
    }
}
