import Observation

/// Remote control's app service (PER-7): the hub and API sources, on/off, pairing and revoke.
/// A P7-6 slot, filled by P7-12; `flush` stops it and revokes every device at quit.
@Observable
@MainActor
final class RemoteControlController {
    func start(environment: AppEnvironment) {}

    func stop() async {}
}
