import AletheExtensionSDK
import ExtensionFoundation
import ExtensionKit
import SwiftUI

/// A sample third-party Alethe extension (P4-19): a right-sidebar tab, one command, and a counter
/// kept in host storage (the `storage` capability). It runs in its own sandboxed process; the
/// debug-only Crash button proves a crash stays out of Alethe.
@main
struct SampleSidebarExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.kc1t.alethe.mac", name: "sidebar-tab")
    }

    var configuration: AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(
            PrimitiveAppExtensionScene(id: AletheExtensionPoint.sidebarSceneID) {
                SampleSidebarView()
            } onConnection: { connection in
                HostBridge.shared.accept(connection, exporting: nil)
            },
            configuration: ConnectionHandler(onConnection: { connection in
                HostBridge.shared.accept(connection, exporting: SampleService())
            })
        )
    }
}

enum SampleManifest {
    static let incrementCommand = "sample.increment"

    static var payload: ExtensionManifestPayload {
        ExtensionManifestPayload(
            name: String(localized: "sample.name"),
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            capabilities: ["storage"],
            commands: [.init(id: incrementCommand, title: String(localized: "sample.command.increment"))],
            sidebarTab: .init(title: String(localized: "sample.name"), symbol: "puzzlepiece.extension")
        )
    }
}

/// The extension's side of the process connection: manifest and commands.
final class SampleService: NSObject, AletheExtensionXPC {
    func manifest(reply: @escaping @Sendable (Data) -> Void) {
        // XPC delivers this on a background queue; building the manifest needs no actor.
        reply(ExtensionWire.encode(SampleManifest.payload))
    }

    func runCommand(_ id: String, reply: @escaping @Sendable (String?) -> Void) {
        guard id == SampleManifest.incrementCommand else { return reply(nil) }
        Task {
            let value = await HostBridge.shared.incrementCounter()
            reply(value.map { String(format: String(localized: "sample.counter"), $0) }
                  ?? String(localized: "sample.storageDenied"))
        }
    }
}
