import AletheFoundation
import AppKit

/// Quits and reopens Alethe (a new interface language only applies at launch).
@MainActor
enum AppRelaunch {
    static func relaunch() {
        // A helper shell waits for this process to finish quitting (documents are flushed on the
        // way out, and a second copy would otherwise exit at once), then opens the app again with
        // the same arguments minus any language override.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open -n \"$0\" --args \"$@\""
        let helper = Process()
        helper.executableURL = URL(filePath: "/bin/sh")
        helper.arguments = ["-c", script, Bundle.main.bundlePath]
            + LanguageSetting.relaunchArguments(Array(CommandLine.arguments.dropFirst()))
        do {
            try helper.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
