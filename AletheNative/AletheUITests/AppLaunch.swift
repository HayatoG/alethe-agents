import XCTest

/// Launches the app against a throwaway data folder, in English, so tests never touch real data and
/// menu titles are predictable.
@MainActor
func launchAlethe(dataRoot: URL = makeTemporaryDataRoot(), arguments: [String] = []) -> (XCUIApplication, URL) {
    let app = XCUIApplication()
    app.launchArguments = ["-AletheDataRoot", dataRoot.path, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
    app.launch()
    return (app, dataRoot)
}

/// Outside the (sandboxed) test runner's container: the app creates it. The runner never reads it —
/// tests verify persistence by relaunching the app and checking its UI.
func makeTemporaryDataRoot() -> URL {
    URL(filePath: "/private/tmp/alethe-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
}

/// Polls `condition` for up to `timeout` seconds.
func eventually(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    return condition()
}

