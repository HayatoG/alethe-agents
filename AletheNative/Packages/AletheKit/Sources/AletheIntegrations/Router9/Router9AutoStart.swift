import AletheModel

extension Router9Source {
    /// The saved preference (`AletheModel.Router9Source`) as the service's source.
    public init(_ preference: AletheModel.Router9Source) {
        switch preference {
        case .managed: self = .managed
        case .external: self = .external
        }
    }
}

extension Router9RoutingConfig {
    /// The saved preferences plus the Keychain's API key (never stored in preferences).
    public init(_ preferences: Router9Preferences, apiKey: String) {
        self.init(enabled: preferences.enabled, port: preferences.port, apiKey: apiKey)
    }
}

extension Router9 {
    /// Whether a launch may even look at 9router: only when the user turned it and auto-start on
    /// (upstream `useRouter9AutoStart` returns before probing otherwise).
    public static func wantsAutoStart(_ preferences: Router9Preferences) -> Bool {
        preferences.enabled && preferences.autoStart
    }

    /// The install to start at launch (upstream `useRouter9AutoStart`): enabled, auto-start on, an
    /// install exists, and nothing runs or holds the port yet. Nil means leave it alone.
    public static func autoStartSource(_ preferences: Router9Preferences, status: Router9Status?) -> Router9Source? {
        guard wantsAutoStart(preferences), let status, !status.running, !status.portInUse else { return nil }
        return resolveSource(status, preferred: Router9Source(preferences.source))?.source
    }
}
