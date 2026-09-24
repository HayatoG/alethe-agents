import Foundation
import Markdown

/// A Markdown file as blocks a SwiftUI view can lay out (upstream renders with react-markdown +
/// remark-gfm). Parsing is swift-markdown (cmark-gfm, ADR-11): CommonMark plus GFM tables, task
/// lists, strikethrough and autolinks. Inline text becomes `AttributedString` with
/// `inlinePresentationIntent` (emphasis, strong, code, strikethrough) and `link`, which SwiftUI's
/// `Text` renders. Relative links and images resolve against the file's folder.
public indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    /// A paragraph that is only an image.
    case image(source: URL?, alt: String)
    case code(language: String?, code: String)
    case quote([MarkdownBlock])
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case table(header: [AttributedString], alignments: [MarkdownColumnAlignment], rows: [[AttributedString]])
    case rule
    /// Raw HTML is not rendered (as upstream, which does not enable rehype-raw); shown as source.
    case html(String)
}

public struct MarkdownListItem: Hashable, Sendable {
    /// nil: plain item; true / false: a GFM task, checked or not.
    public var checkbox: Bool?
    public var blocks: [MarkdownBlock]
}

public enum MarkdownColumnAlignment: Hashable, Sendable {
    case leading, center, trailing
}

public enum MarkdownBlocks {
    /// - Parameter base: the file's folder, for relative links and images.
    public static func parse(_ text: String, base: URL? = nil) -> [MarkdownBlock] {
        let document = Document(parsing: text)
        let converter = Converter(base: base)
        return document.children.compactMap { converter.block($0) }
    }

    /// `destination` as a URL: absolute URLs as they are, anything else relative to `base`. Fragments
    /// alone (`#section`) have nowhere to go outside a web view and are dropped.
    static func resolve(_ destination: String?, base: URL?) -> URL? {
        guard let destination = destination?.trimmingCharacters(in: .whitespaces), !destination.isEmpty,
              !destination.hasPrefix("#") else { return nil }
        if let url = URL(string: destination), url.scheme != nil { return url }
        let path = destination.removingPercentEncoding ?? destination
        if path.hasPrefix("/") { return URL(filePath: path) }
        guard let base else { return URL(string: destination) }
        let withoutFragment = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        return base.appending(path: withoutFragment).standardizedFileURL
    }
}

private struct Converter {
    let base: URL?

    func block(_ markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, text: inlines(heading.children))
        case let paragraph as Paragraph:
            let children = Array(paragraph.children)
            if children.count == 1, let image = children.first as? Markdown.Image {
                return .image(source: MarkdownBlocks.resolve(image.source, base: base), alt: image.plainText)
            }
            return .paragraph(inlines(children))
        case let code as CodeBlock:
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            return .code(language: language, code: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
        case let quote as BlockQuote:
            return .quote(quote.children.compactMap { block($0) })
        case let list as OrderedList:
            return .list(ordered: true, start: Int(list.startIndex), items: items(list.children))
        case let list as UnorderedList:
            return .list(ordered: false, start: 1, items: items(list.children))
        case let table as Markdown.Table:
            let alignments = table.columnAlignments.map { alignment -> MarkdownColumnAlignment in
                switch alignment {
                case .center: .center
                case .right: .trailing
                default: .leading
                }
            }
            let header = Array(table.head.cells.map { inlines($0.children) })
            let rows = Array(table.body.rows.map { row in Array(row.cells.map { inlines($0.children) }) })
            let width = max(header.count, rows.map(\.count).max() ?? 0)
            return .table(header: pad(header, to: width),
                          alignments: alignments + Array(repeating: .leading, count: max(0, width - alignments.count)),
                          rows: rows.map { pad($0, to: width) })
        case is ThematicBreak:
            return .rule
        case let html as HTMLBlock:
            return .html(html.rawHTML.trimmingCharacters(in: .newlines))
        default:
            return nil
        }
    }

    private func pad(_ cells: [AttributedString], to width: Int) -> [AttributedString] {
        cells + Array(repeating: AttributedString(), count: max(0, width - cells.count))
    }

    private func items(_ children: some Sequence<Markup>) -> [MarkdownListItem] {
        children.compactMap { child -> MarkdownListItem? in
            guard let item = child as? ListItem else { return nil }
            let checkbox: Bool? = item.checkbox.map { $0 == .checked }
            return MarkdownListItem(checkbox: checkbox, blocks: item.children.compactMap { block($0) })
        }
    }

    func inlines(_ children: some Sequence<Markup>) -> AttributedString {
        var result = AttributedString()
        for child in children { result += inline(child, intent: []) }
        return result
    }

    private func inline(_ markup: Markup, intent: InlinePresentationIntent) -> AttributedString {
        func styled(_ string: String, _ extra: InlinePresentationIntent = []) -> AttributedString {
            var text = AttributedString(string)
            let combined = intent.union(extra)
            if !combined.isEmpty { text.inlinePresentationIntent = combined }
            return text
        }
        func nested(_ children: some Sequence<Markup>, _ extra: InlinePresentationIntent) -> AttributedString {
            var result = AttributedString()
            for child in children { result += inline(child, intent: intent.union(extra)) }
            return result
        }
        switch markup {
        case let text as Markdown.Text:
            return styled(text.string)
        case let emphasis as Emphasis:
            return nested(emphasis.children, .emphasized)
        case let strong as Strong:
            return nested(strong.children, .stronglyEmphasized)
        case let strike as Strikethrough:
            return nested(strike.children, .strikethrough)
        case let code as InlineCode:
            return styled(code.code, .code)
        case let link as Markdown.Link:
            var text = nested(link.children, [])
            if let url = MarkdownBlocks.resolve(link.destination, base: base) { text.link = url }
            return text
        case let image as Markdown.Image:
            // An image inside running text: its description, linked to the image.
            var text = styled(image.plainText.isEmpty ? (image.source ?? "") : image.plainText)
            if let url = MarkdownBlocks.resolve(image.source, base: base) { text.link = url }
            return text
        case is SoftBreak:
            return styled(" ")
        case is LineBreak:
            return styled("\n")
        case let html as InlineHTML:
            return styled(html.rawHTML, .code)
        case let symbol as SymbolLink:
            return styled(symbol.destination ?? "", .code)
        default:
            if let container = markup as? InlineContainer { return nested(container.children, []) }
            return styled(markup.format())
        }
    }
}
