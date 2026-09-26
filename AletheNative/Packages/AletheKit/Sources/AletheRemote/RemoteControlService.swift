import Foundation

/// The user's remote control choices pushed to the hub (upstream `useRemoteControlService` sync).
/// Whether it is on is not part of it: remote control is off at every launch.
public struct RemoteControlSettings: Equatable, Sendable {
    public var maxDevices: Int
    public var sessionExpirySecs: Int
    public var readOnly: Bool
    public var allowShellInput: Bool
    public var reachMode: RemoteReachMode

    public init(maxDevices: Int = 1, sessionExpirySecs: Int = Int(RemoteLimits.defaultSessionExpiry), readOnly: Bool = true,
                allowShellInput: Bool = false, reachMode: RemoteReachMode = .lan) {
        self.maxDevices = maxDevices
        self.sessionExpirySecs = sessionExpirySecs
        self.readOnly = readOnly
        self.allowShellInput = allowShellInput
        self.reachMode = reachMode
    }
}

/// Remote control's commands (upstream `remote/commands.rs`) over one hub, its API and transport:
/// on and off, settings, pairing and revoking. Nothing binds until `setEnabled(true)`; `stop`
/// revokes every device and closes every connection.
public actor RemoteControlService {
    public nonisolated let hub: RemoteHub
    private let transport: RemoteTransport

    public init(
        hub: RemoteHub = RemoteHub(),
        terminals: any RemoteTerminalSource,
        workspace: any RemoteWorkspaceSource,
        assets: any RemoteAssetSource,
        configuration: RemoteTransport.Configuration = .standard
    ) {
        self.hub = hub
        let api = RemoteAPI(hub: hub, terminals: terminals, workspace: workspace, assets: assets)
        transport = RemoteTransport(hub: hub, router: api, terminals: terminals, workspace: workspace,
                                    configuration: configuration)
    }

    /// Message, start-failed and auto-disabled events; one consumer.
    public nonisolated var events: AsyncStream<RemoteEvent> { hub.events }

    public func info() async -> RemoteInfo {
        await hub.info()
    }

    /// Turns the listeners on or off (upstream `remote_control_set_enabled`). A failed start emits
    /// `.startFailed` and reports remote control off.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> RemoteInfo {
        if enabled {
            await transport.start()
        } else {
            await transport.stop()
        }
        return await hub.info()
    }

    /// Pushes the settings; returns whether the listeners were restarted, which happens only when
    /// the reach mode changed while running (upstream `remote_control_set_reach_mode`: the sync
    /// re-sends every setting, and a restart drops every device).
    @discardableResult
    public func apply(_ settings: RemoteControlSettings) async -> Bool {
        await hub.setMaxDevices(settings.maxDevices)
        await hub.setSessionExpiry(TimeInterval(settings.sessionExpirySecs))
        await hub.setReadOnly(settings.readOnly)
        await hub.setAllowShellInput(settings.allowShellInput)
        guard await hub.setReachMode(settings.reachMode), await hub.isEnabled else { return false }
        await transport.stop()
        await transport.start()
        return true
    }

    /// Opens the 120 s pairing window on a freshly resolved host (upstream
    /// `remote_control_open_pairing`); nothing while remote control is off.
    @discardableResult
    public func openPairing() async -> RemoteInfo {
        if await hub.isEnabled {
            await hub.refreshHost()
            await hub.openPairingWindow()
        }
        return await hub.info()
    }

    @discardableResult
    public func closePairing() async -> RemoteInfo {
        await hub.closePairingWindow()
        return await hub.info()
    }

    @discardableResult
    public func revoke(deviceID: Int) async -> RemoteInfo {
        await hub.revokeDevice(deviceID)
        return await hub.info()
    }

    /// Every device loses access and pairing closes (upstream `remote_control_revoke`).
    @discardableResult
    public func revokeAll() async -> RemoteInfo {
        await hub.revokeAll()
        await hub.closePairingWindow()
        return await hub.info()
    }

    /// Quitting: listeners and connections close, every device is revoked.
    public func stop() async {
        await transport.stop()
    }
}
