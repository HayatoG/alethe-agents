import Foundation

/// Something a worker's report points at that the board can show (upstream `lib/orchestratorMedia.ts`).
public struct MediaItem: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case imageLocal = "image-local"
        case imageURL = "image-url"
        case link
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

public enum BoardMedia {
    public static let maxItems = 4

    // Absolute POSIX paths (and `~/`) where upstream matches drive letters. The lookbehind keeps a
    // URL's own path (`https://host/a.png`) and relative segments (`out/a.png`) from matching.
    private static let localPath = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9:/~._\-])~?/[^\s"'`/][^\s"'`]*"#)
    private static let url = try! NSRegularExpression(pattern: #"https?://[^\s"'`)]+"#)
    private static let imageExtension = try! NSRegularExpression(pattern: #"\.(png|jpe?g|gif|webp|svg)$"#, options: .caseInsensitive)
    private static let trailingPunctuation = try! NSRegularExpression(pattern: #"[.,;:!?)\]]+$"#)

    /// Upstream `extractMediaItems`: local images first, then image URLs and links, deduplicated,
    /// at most `maxItems`. A plain link already written as a markdown link target is left out.
    public static func extract(_ text: String) -> [MediaItem] {
        var items: [MediaItem] = []
        var seen = Set<String>()

        for raw in matches(localPath, in: text) {
            let value = stripTrailingPunctuation(raw)
            if seen.contains(value) || !isImage(value) { continue }
            seen.insert(value)
            items.append(MediaItem(kind: .imageLocal, value: value))
            if items.count >= maxItems { return items }
        }

        for raw in matches(url, in: text) {
            let value = stripTrailingPunctuation(raw)
            let image = isImage(value)
            let alreadyLinked = !image && text.contains("](\(value))")
            if seen.contains(value) || alreadyLinked { continue }
            seen.insert(value)
            items.append(MediaItem(kind: image ? .imageURL : .link, value: value))
            if items.count >= maxItems { return items }
        }

        return items
    }

    /// The one image a worker gets its own canvas card for: the first that is not a plain link.
    public static func promoted(_ report: String) -> MediaItem? {
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return extract(trimmed).first { $0.kind != .link }
    }

    /// What the worker's own strip shows: everything except the promoted image.
    public static func remaining(_ report: String) -> [MediaItem] {
        let trimmed = report.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var items = extract(trimmed)
        if let promoted = items.firstIndex(where: { $0.kind != .link }) { items.remove(at: promoted) }
        return items
    }

    /// The promoted image of every job that has one, keyed by job id (the layout's `mediaByJobID`).
    public static func promotedByJobID(_ jobs: [JobSnapshot]) -> [String: MediaItem] {
        var map: [String: MediaItem] = [:]
        for job in jobs {
            if let item = promoted(job.summary) { map[job.id] = item }
        }
        return map
    }

    private static func matches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func isImage(_ value: String) -> Bool {
        imageExtension.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    private static func stripTrailingPunctuation(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        return trailingPunctuation.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
