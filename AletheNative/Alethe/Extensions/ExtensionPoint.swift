import AletheExtensionSDK
import ExtensionFoundation

extension AppExtensionPoint {
    /// Alethe's extension point for third-party plugins (ADR-9). The build extracts this definition
    /// into `Contents/Extensions/Alethe.appexpt`; extensions bind to it with
    /// `AppExtensionPoint.Identifier(host: "com.kc1t.alethe.mac", name: "sidebar-tab")`.
    /// `Scope(.none)` admits extensions shipped in other apps; `UserInterface` allows the remote
    /// sidebar scene.
    @Definition
    static var aletheSidebarTab: AppExtensionPoint {
        Name("sidebar-tab")
        Scope(restriction: .none)
        UserInterface(true)
    }
}
