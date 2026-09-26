import Observation

/// 9router's runtime in the app (PER-5; upstream `useRouter9Runtime`, `useRouter9AutoStart`).
/// A P7-6 slot, filled by P7-16; `flush` stops a managed 9router at quit.
@Observable
@MainActor
final class Router9Controller {
    func start(environment: AppEnvironment) {}

    func stop() async {}
}
