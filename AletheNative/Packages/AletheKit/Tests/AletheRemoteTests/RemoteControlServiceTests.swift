import Foundation
import Testing
@testable import AletheRemote

/// Remote control's commands (P7-12, upstream `remote/commands.rs`) over real listeners on
/// 127.0.0.1, in their own port range so they never compete with the transport tests.
@Suite(.serialized)
struct RemoteControlServiceTests {
    private static let configuration = RemoteTransport.Configuration(
        httpPorts: 9400...9420, webSocketPorts: 9401...9421, idleCheckInterval: .seconds(3600))

    private func makeService(lan: String = "127.0.0.1", tailscale: String? = "127.0.0.1") -> RemoteControlService {
        let hub = RemoteHub(resolver: RemoteHostResolver(lanAddress: { lan }, tailscaleAddress: { tailscale }))
        return RemoteControlService(hub: hub, terminals: FakeTerminals(), workspace: FakeWorkspace(),
                                    assets: FakeAssets(), configuration: Self.configuration)
    }

    @Test func nothingIsBoundUntilTurnedOn() async {
        let service = makeService()

        let info = await service.info()
        await service.apply(RemoteControlSettings(maxDevices: 3, readOnly: false))

        #expect(!info.enabled && info.httpURL == nil && info.wsURL == nil)
        #expect(await service.hub.httpPort == 0)
        #expect(await service.openPairing().pairingURL == nil, "pairing needs remote control on")
    }

    @Test func turningOnBindsBothListenersAndOffClosesThem() async {
        let service = makeService()

        let on = await service.setEnabled(true)
        let off = await service.setEnabled(false)

        #expect(on.enabled)
        #expect(on.httpURL?.hasPrefix("http://127.0.0.1:94") == true)
        #expect(on.wsURL?.hasPrefix("ws://127.0.0.1:94") == true)
        #expect(!off.enabled && off.httpURL == nil && off.wsURL == nil)
    }

    @Test func settingsReachTheHub() async {
        let service = makeService()

        await service.apply(RemoteControlSettings(maxDevices: 3, sessionExpirySecs: 600, readOnly: false,
                                                  allowShellInput: true, reachMode: .tailscale))

        let info = await service.info()
        #expect(info.maxDevices == 3 && info.sessionExpirySecs == 600)
        #expect(!info.readOnly && info.allowShellInput && info.reachMode == .tailscale)
    }

    @Test func settingChangesDoNotRestartUnlessTheReachModeChanged() async throws {
        let service = makeService()
        var settings = RemoteControlSettings()
        await service.apply(settings)
        await service.setEnabled(true)
        let generation = await service.hub.generation
        await service.openPairing()
        let pairingURL = try #require(await service.info().pairingURL)

        settings.maxDevices = 4
        settings.readOnly = false
        settings.allowShellInput = true
        settings.sessionExpirySecs = 7_200
        let restarted = await service.apply(settings)

        #expect(!restarted)
        #expect(await service.hub.generation == generation)
        #expect(await service.info().pairingURL == pairingURL, "the pairing window stays open")

        settings.reachMode = .tailscale
        let rebound = await service.apply(settings)

        #expect(rebound)
        #expect(await service.hub.generation > generation)
        let info = await service.info()
        #expect(info.enabled && info.reachMode == .tailscale && info.httpURL != nil)
        #expect(info.pairingURL == nil, "a restart closes pairing")
        await service.stop()
    }

    @Test func aReachModeChangeWhileOffOnlyRecordsIt() async {
        let service = makeService()
        let generation = await service.hub.generation

        let restarted = await service.apply(RemoteControlSettings(reachMode: .tailscale))

        #expect(!restarted)
        #expect(await service.hub.generation == generation)
        #expect(await service.info().reachMode == .tailscale)
    }

    @Test func tailscaleMissingFailsClosedAndReportsIt() async {
        let service = makeService(tailscale: nil)
        await service.apply(RemoteControlSettings(reachMode: .tailscale))
        var events = service.events.makeAsyncIterator()

        let info = await service.setEnabled(true)

        #expect(!info.enabled && info.httpURL == nil)
        #expect(await events.next() == .startFailed)
    }

    @Test func revokingEveryDeviceClosesPairing() async throws {
        let service = makeService()
        await service.apply(RemoteControlSettings(maxDevices: 2))
        await service.setEnabled(true)
        await service.openPairing()
        let first = try await service.hub.pair(token: service.hub.pairingToken, name: "One", address: "127.0.0.1:1")
        await service.openPairing()
        _ = try await service.hub.pair(token: service.hub.pairingToken, name: "Two", address: "127.0.0.1:2")

        let afterOne = await service.revoke(deviceID: first.deviceID)
        #expect(afterOne.devices.map(\.name) == ["Two"])

        await service.openPairing()
        let afterAll = await service.revokeAll()
        #expect(afterAll.devices.isEmpty && !afterAll.pairingOpen)
        await service.stop()
    }

    @Test func stoppingRevokesEveryDeviceAndUnbinds() async throws {
        let service = makeService()
        await service.setEnabled(true)
        await service.openPairing()
        let pairing = try await service.hub.pair(token: service.hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        await service.stop()

        let info = await service.info()
        #expect(!info.enabled && info.devices.isEmpty && info.httpURL == nil)
        #expect(await service.hub.sessionID(for: pairing.sessionToken) == nil)
    }
}
