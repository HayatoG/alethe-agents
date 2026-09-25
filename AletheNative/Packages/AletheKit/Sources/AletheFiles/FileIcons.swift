import Foundation

/// SF Symbol names per file type, ported from upstream `FileIcon.tsx` (lucide icons).
public enum FileIcons {
    public static let folderSymbol = "folder"
    public static let openFolderSymbol = "folder.fill"
    public static let defaultSymbol = "doc"

    private static let groups: [(symbol: String, extensions: Set<String>)] = [
        ("curlybraces", ["json"]),
        ("slider.horizontal.3", ["yaml", "yml", "toml", "ini"]),
        ("cylinder", ["sql", "db", "sqlite"]),
        ("terminal", ["sh", "bash", "zsh", "ps1", "bat", "cmd"]),
        ("chevron.left.forwardslash.chevron.right", [
            "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rs", "go", "c", "cpp", "h", "hpp",
            "cs", "java", "html", "htm", "css", "scss", "less",
        ]),
        ("photo", ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico", "bmp", "avif"]),
        ("film", ["mp4", "mov", "webm", "m4v", "ogv"]),
        ("waveform", ["mp3", "wav", "ogg", "flac", "aac"]),
        ("tablecells", ["csv", "tsv", "xlsx", "xls"]),
        ("archivebox", ["zip", "tar", "gz", "7z", "rar"]),
        ("doc.text", ["md", "markdown", "mdx", "txt", "pdf"]),
    ]

    public static func symbolName(forFileName fileName: String) -> String {
        let lower = fileName.lowercased()
        if [".gitignore", ".gitattributes", ".gitmodules"].contains(lower) { return "arrow.triangle.branch" }
        if lower == "dockerfile" || lower.hasPrefix("docker-compose") || lower == ".dockerignore" {
            return "shippingbox"
        }
        if lower == ".env" || lower.hasPrefix(".env.") { return "key" }
        guard let dot = lower.lastIndex(of: "."), dot != lower.startIndex else { return defaultSymbol }
        let ext = String(lower[lower.index(after: dot)...])
        return groups.first { $0.extensions.contains(ext) }?.symbol ?? defaultSymbol
    }
}

/// Which pane opens a file (upstream `classifyPaneKind`; HTML and PDF go to the web pane natively).
public enum FilePaneKind: String, Hashable, Sendable, CaseIterable {
    case markdown, image, video, text, web

    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "mkv", "webm", "ogv"]
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "avif", "ico", "svg"]
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdx"]
    private static let webExtensions: Set<String> = ["html", "htm", "pdf"]

    /// Classifies a path; a trailing `:line[:column]` suffix is ignored like upstream.
    public static func forFile(_ path: String) -> FilePaneKind {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #":\d+(?::\d+)?$"#, with: "", options: .regularExpression)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if imageExtensions.contains(ext) { return .image }
        if markdownExtensions.contains(ext) { return .markdown }
        if webExtensions.contains(ext) { return .web }
        return .text
    }
}
