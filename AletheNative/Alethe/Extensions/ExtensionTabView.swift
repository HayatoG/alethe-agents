import AletheDesign
import AletheExtensionHost
import ExtensionFoundation
import ExtensionKit
import SwiftUI

/// A third-party extension's sidebar tab: its remote scene in an `EXHostViewController`. When the
/// extension's process exits or crashes, the tab shows a stopped state with Reload; Alethe itself
/// keeps running (the extension lives in its own process).
struct ExtensionTabView: View {
    let identity: AppExtensionIdentity
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var stopped = false
    /// Bumped by Reload to build a fresh host view controller.
    @State private var generation = 0

    /// The tab's scene or the extension's process stopped.
    private var isStopped: Bool {
        stopped || environment.extensions?.entries.first { $0.id == identity.bundleIdentifier }?.status == .stopped
    }

    var body: some View {
        if isStopped {
            ContentUnavailableView {
                Label("extensions.stopped.title", systemImage: "exclamationmark.octagon")
            } description: {
                Text("extensions.stopped.message")
            } actions: {
                Button("extensions.stopped.reload") {
                    environment.extensions?.reload(identity.bundleIdentifier)
                    stopped = false
                    generation += 1
                }
                .accessibilityIdentifier("extensions.stopped.reload")
            }
            .foregroundStyle(theme[.textSecondary])
            .accessibilityIdentifier("extensions.stopped")
        } else {
            ExtensionHostRepresentable(identity: identity, manager: environment.extensions) {
                stopped = true
            }
            .id(generation)
            .accessibilityIdentifier("extensions.tab.\(identity.bundleIdentifier)")
        }
    }
}

private struct ExtensionHostRepresentable: NSViewControllerRepresentable {
    let identity: AppExtensionIdentity
    let manager: ExtensionManager?
    let onStop: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(bundleIdentifier: identity.bundleIdentifier, manager: manager, onStop: onStop)
    }

    func makeNSViewController(context: Context) -> EXHostViewController {
        let controller = EXHostViewController()
        controller.delegate = context.coordinator
        controller.placeholderView = NSHostingView(rootView: ProgressView().controlSize(.small))
        controller.configuration = .init(appExtension: identity, sceneID: AletheExtensionPoint.sidebarSceneID)
        return controller
    }

    func updateNSViewController(_ controller: EXHostViewController, context: Context) {}

    static func dismantleNSViewController(_ controller: EXHostViewController, coordinator: Coordinator) {
        coordinator.connection?.invalidate()
        controller.configuration = nil
    }

    @MainActor
    final class Coordinator: NSObject, EXHostViewControllerDelegate {
        let bundleIdentifier: String
        weak var manager: ExtensionManager?
        let onStop: @MainActor () -> Void
        var connection: NSXPCConnection?

        init(bundleIdentifier: String, manager: ExtensionManager?, onStop: @escaping @MainActor () -> Void) {
            self.bundleIdentifier = bundleIdentifier
            self.manager = manager
            self.onStop = onStop
        }

        /// The scene gets its own connection; the host serves storage on it too.
        func hostViewControllerDidActivate(_ viewController: EXHostViewController) {
            guard let manager, let connection = try? viewController.makeXPCConnection() else { return }
            manager.configureHostSide(of: connection, for: bundleIdentifier)
            connection.resume()
            self.connection = connection
        }

        /// A nil error is a clean exit (for example, the tab was closed); anything else is a crash.
        func hostViewControllerWillDeactivate(_ viewController: EXHostViewController, error: (any Error)?) {
            connection?.invalidate()
            connection = nil
            if error != nil { onStop() }
        }
    }
}
