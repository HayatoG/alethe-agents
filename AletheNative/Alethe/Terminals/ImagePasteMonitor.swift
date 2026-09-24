import AletheTerminal
import AppKit

/// ⌘V in a terminal with only an image on the pasteboard (a screenshot, "Copy Image"): Ghostty's own
/// paste reads text and file URLs only, so the image is saved and its path pasted instead
/// (`TerminalPaneView.pasteImageIfNeeded`). Every other ⌘V goes on untouched. A local monitor sees
/// the key before the terminal view's key equivalents.
@MainActor
enum ImagePasteMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v",
                      let terminal = (event.window?.firstResponder as? NSView)?.enclosingTerminal,
                      terminal.pasteImageIfNeeded() else { return event }
                return nil
            }
        }
    }
}

private extension NSView {
    var enclosingTerminal: TerminalPaneView? {
        var view: NSView? = self
        while let current = view {
            if let terminal = current as? TerminalPaneView { return terminal }
            view = current.superview
        }
        return nil
    }
}
