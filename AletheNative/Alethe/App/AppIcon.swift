import AletheModel
import AppKit

/// The Dock icon follows `PreferencesDocument.iconTheme` (P5-12, upstream `setIcon`). Only the running
/// app's image changes: rewriting the bundle's icon would break its signature.
@MainActor
enum AppIcon {
    private static var applied: AppIconTheme?

    static func image(for theme: AppIconTheme) -> NSImage? {
        NSImage(named: theme.assetName)
    }

    static func apply(_ theme: AppIconTheme) {
        guard theme != applied, let image = image(for: theme) else { return }
        NSApp.applicationIconImage = image
        applied = theme
    }
}

extension AppEnvironment {
    /// Applies the chosen icon now and again whenever it changes.
    func followAppIcon() {
        let theme = withObservationTracking {
            preferences?.document.iconTheme ?? .default
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAppIcon() }
        }
        AppIcon.apply(theme)
    }
}
