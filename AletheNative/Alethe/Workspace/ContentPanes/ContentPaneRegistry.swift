import AletheDocuments
import AletheModel
import AVFoundation
import Observation

/// Open file-backed panes (Markdown, image, video), one model per pane, kept while the pane exists so a
/// draft or a scroll position survives layout changes. The terminal counterpart is
/// `TerminalRegistry`.
@MainActor
final class ContentPaneRegistry {
    private var markdown: [PaneID: MarkdownFile] = [:]
    private var images: [PaneID: ImageFile] = [:]
    private var players: [PaneID: (path: String, player: AVPlayer)] = [:]

    func image(for pane: PaneID, path: String) -> ImageFile {
        if let file = images[pane], file.url.path == URL(filePath: path).path { return file }
        images[pane]?.close()
        let file = ImageFile(path: path)
        images[pane] = file
        return file
    }

    func player(for pane: PaneID, path: String) -> AVPlayer {
        if let entry = players[pane], entry.path == path { return entry.player }
        players[pane]?.player.pause()
        let player = AVPlayer(url: URL(filePath: path))
        players[pane] = (path, player)
        return player
    }

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
        for (pane, file) in images where !panes.contains(pane) {
            file.close()
            images.removeValue(forKey: pane)
        }
        for (pane, entry) in players where !panes.contains(pane) {
            entry.player.pause()
            players.removeValue(forKey: pane)
        }
    }
}
