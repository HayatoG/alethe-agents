import AletheDocuments
import AletheModel
import Observation

/// Open file-backed panes (Markdown today), one model per pane, kept while the pane exists so a
/// draft or a scroll position survives layout changes. The terminal counterpart is
/// `TerminalRegistry`.
@MainActor
final class ContentPaneRegistry {
    private var markdown: [PaneID: MarkdownFile] = [:]

    func markdown(for pane: PaneID, path: String) -> MarkdownFile {
        if let file = markdown[pane], file.path == path { return file }
        markdown[pane]?.close()
        let file = MarkdownFile(path: path)
        markdown[pane] = file
        return file
    }

    /// Closes the models of panes that no longer exist.
    func prune(keeping panes: Set<PaneID>) {
        for (pane, file) in markdown where !panes.contains(pane) {
            file.close()
            markdown.removeValue(forKey: pane)
        }
    }
}
