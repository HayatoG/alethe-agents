import AlethePluginKit
import Foundation

/// Built-in Git Control plugin (upstream `plugins/git-control`; ADR-9 dogfooding): contributes the
/// "Git Control…" command and the sheet the app renders for `viewID`. Disabling it removes both, so
/// the app hides its menu entries.
@MainActor
public final class GitControlPlugin: AlethePlugin {
    public static let manifest = PluginManifest(
        id: "com.alethe.git-control",
        version: "1.0.0",
        name: "Git Control",
        capabilities: [.git]
    )

    public static let sheetID = "gitControl"
    public static let viewID = "gitControl"
    public static let openCommandID = "gitControl.open"

    /// Set by the app to present the sheet for the selected project.
    public static var onOpen: (@MainActor () -> Void)?

    public init() {}

    public func activate(context: PluginContext) throws {
        try context.require(.git)
        try context.addSheet(SheetContribution(id: Self.sheetID, title: "Git Control", viewID: Self.viewID))
        try context.addCommand(CommandContribution(id: Self.openCommandID, title: "Git Control…") {
            GitControlPlugin.onOpen?()
        })
    }
}
