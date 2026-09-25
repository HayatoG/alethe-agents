import AletheFoundation
import AletheModel
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak var environment: AppEnvironment?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One Alethe per user session: a second copy would own the same data files and terminals.
        // Debug builds pointed at their own data root (UI tests, experiments) may run side by side.
        #if DEBUG
        if UserDefaults.standard.string(forKey: "AletheDataRoot") != nil { return }
        #endif
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
        if let existing = others.first {
            existing.activate()
            exit(0)
        }
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        ImagePasteMonitor.install()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let confirmed = MainActor.assumeIsolated { confirmQuit() }
        guard confirmed else { return .terminateCancel }
        Task { @MainActor in
            await environment?.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting stops every terminal (upstream `useCloseConfirmation`): ask first while any runs,
    /// unless the user turned the question off (also from the alert itself).
    @MainActor private func confirmQuit() -> Bool {
        guard let environment, environment.preferences?.document.confirmQuit != false else { return true }
        #if DEBUG
        // Smoke scripts quit throwaway instances with AppleScript; UI tests opt in explicitly.
        if UserDefaults.standard.string(forKey: "AletheDataRoot") != nil,
           !UserDefaults.standard.bool(forKey: "AletheConfirmQuit") { return true }
        #endif
        let running = environment.runningTerminals
        guard running.agents + running.shells > 0 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "quit.title")
        alert.informativeText = String(format: String(localized: "quit.message"), running.agents, running.shells)
        alert.addButton(withTitle: String(localized: "quit.confirm"))
        alert.addButton(withTitle: String(localized: "editor.cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "quit.dontAsk")
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on, answer == .alertFirstButtonReturn {
            environment.preferences?.update { $0.confirmQuit = false }
        }
        return answer == .alertFirstButtonReturn
    }
}
