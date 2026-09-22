import AletheFoundation
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await environment?.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
