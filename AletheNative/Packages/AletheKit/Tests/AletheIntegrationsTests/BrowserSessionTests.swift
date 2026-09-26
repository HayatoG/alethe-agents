import Darwin
import Foundation
import Testing
import XCTest
@testable import AletheIntegrations

struct PlaywrightMcpTests {
    @Test func sharedModeAttachesToTheRunningBrowser() {
        let arguments = PlaywrightMcp.arguments(mode: .shared, dedicatedHeadless: true, sharedEndpoint: "http://127.0.0.1:4321")
        #expect(arguments == ["-y", "@playwright/mcp@latest", "--cdp-endpoint", "http://127.0.0.1:4321"])
    }

    @Test func sharedModeWithoutABrowserFallsBackToPlaywrightsDefault() {
        // Starting an agent must never start a browser just to fill in --cdp-endpoint.
        let arguments = PlaywrightMcp.arguments(mode: .shared, dedicatedHeadless: true, sharedEndpoint: nil)
        #expect(arguments == ["-y", "@playwright/mcp@latest"])
    }

    @Test func dedicatedModeNeverAttaches() {
        let headless = PlaywrightMcp.arguments(mode: .dedicated, dedicatedHeadless: true, sharedEndpoint: "http://127.0.0.1:9")
        #expect(headless == ["-y", "@playwright/mcp@latest", "--headless"])
        let headed = PlaywrightMcp.arguments(mode: .dedicated, dedicatedHeadless: false, sharedEndpoint: "http://127.0.0.1:9")
        #expect(headed == ["-y", "@playwright/mcp@latest"], "headed is Playwright's default: the flag is omitted")
    }

    @Test func anEndpointWinsOverTheHeadlessFlag() {
        let arguments = PlaywrightMcp.arguments(endpoint: "http://127.0.0.1:9", dedicatedHeadless: true)
        #expect(!arguments.contains("--headless"))
        #expect(arguments.contains("--cdp-endpoint"))
    }
}

@Suite(.timeLimit(.minutes(1))) struct BrowserLaunchTests {
    private let profile = URL(filePath: "/Users/me/Library/Application Support/Alethe/profiles/default/browser-session",
                              directoryHint: .isDirectory)

    @Test func endpointIsLoopbackOnly() {
        #expect(BrowserLaunch.endpoint(port: 9333) == "http://127.0.0.1:9333")
        let arguments = BrowserLaunch.arguments(port: 9333, profileDirectory: profile, headless: false)
        #expect(arguments.contains("--remote-debugging-address=127.0.0.1"))
        #expect(!arguments.joined(separator: " ").contains("0.0.0.0"))
    }

    @Test func argumentsCarryPortAndProfile() {
        let arguments = BrowserLaunch.arguments(port: 9333, profileDirectory: profile, headless: false)
        #expect(arguments.contains("--remote-debugging-port=9333"))
        #expect(arguments.contains("--user-data-dir=\(profile.path)"))
        #expect(arguments.last == "about:blank")
    }

    @Test func headlessIsAChoiceSinceTheBrowserHasNoPane() {
        let headed = BrowserLaunch.arguments(port: 1, profileDirectory: profile, headless: false)
        #expect(!headed.contains { $0.hasPrefix("--headless") })
        let headless = BrowserLaunch.arguments(port: 1, profileDirectory: profile, headless: true)
        #expect(headless.contains("--headless=new"))
    }

    @Test func freePortIsBindableOnLoopback() throws {
        let port = try BrowserLaunch.freePort()
        #expect(port > 0)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        #expect(bound)
    }

    @Test func staleMatchingNeedsABrowserAndThisExactProfile() {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        let own = ["Google Chrome", "--remote-debugging-port=1", "--user-data-dir=\(profile.path)"]
        #expect(BrowserLaunch.isStale(executable: chrome, arguments: own, profileDirectory: profile))
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/x/Google Chrome Helper (Renderer)"
        #expect(BrowserLaunch.isStale(executable: helper, arguments: own, profileDirectory: profile))
        // The user's own browser, or another profile.
        #expect(!BrowserLaunch.isStale(executable: chrome, arguments: ["Google Chrome"], profileDirectory: profile))
        #expect(!BrowserLaunch.isStale(executable: chrome, arguments: ["Google Chrome", "--user-data-dir=\(profile.path)-other"],
                                       profileDirectory: profile))
    }

    @Test func staleMatchingNeverReachesAShellOrAnAgent() {
        // They can carry the profile path in their command line; killing one would take a terminal
        // (or the app) down with it.
        let mention = ["x", "--user-data-dir=\(profile.path)"]
        for innocent in ["/bin/zsh", "/bin/bash", "/usr/local/bin/node", "/opt/homebrew/bin/claude",
                         "/Applications/Alethe.app/Contents/MacOS/Alethe", "/usr/bin/vim", "/usr/bin/grep"] {
            #expect(!BrowserLaunch.isStale(executable: innocent, arguments: mention, profileDirectory: profile))
        }
        // argv[0] alone never counts.
        #expect(!BrowserLaunch.isStale(executable: "/Applications/Chromium.app/Contents/MacOS/Chromium",
                                       arguments: ["--user-data-dir=\(profile.path)"], profileDirectory: profile))
    }

    @Test func everyBrowserSpellingIsReapable() {
        for browser in ["Google Chrome", "Chromium", "Microsoft Edge", "Brave Browser", "Google Chrome Helper (GPU)",
                        "Microsoft Edge Helper"] {
            #expect(BrowserLaunch.isBrowserExecutable("/x/\(browser)"), "\(browser)")
        }
    }

    @Test func anExplicitMissingExecutableIsRejected() {
        #expect(throws: BrowserSessionError.browserNotFound) {
            try BrowserLaunch.resolve(explicit: "/nonexistent/browser", candidates: [], isExecutable: { _ in false })
        }
    }

    @Test func aBlankExplicitPathFallsBackToDiscovery() throws {
        let second = URL(filePath: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge")
        let candidates = [URL(filePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"), second]
        let found = try BrowserLaunch.resolve(explicit: "   ", candidates: candidates, isExecutable: { $0 == second.path })
        #expect(found == second)
        #expect(throws: BrowserSessionError.browserNotFound) {
            try BrowserLaunch.resolve(explicit: nil, candidates: candidates, isExecutable: { _ in false })
        }
    }

    @Test func candidatesCoverEveryBrowserInBothApplicationFolders() {
        let paths = BrowserLaunch.candidates(home: URL(filePath: "/Users/me", directoryHint: .isDirectory)).map(\.path)
        #expect(paths.first == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        #expect(paths.contains("/Users/me/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"))
        #expect(paths.count == 8)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ProcessTableTests {
    @Test func procArgsAreParsedPastThePadding() {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/Applications/Chromium.app/Contents/MacOS/Chromium".utf8) + [0, 0, 0, 0]
        for argument in ["Chromium", "--user-data-dir=/p", "about:blank"] { bytes += Array(argument.utf8) + [0] }
        bytes += Array("PATH=/usr/bin".utf8) + [0]
        let parsed = ProcessTable.parseProcArgs(bytes)
        #expect(parsed?.executable == "/Applications/Chromium.app/Contents/MacOS/Chromium")
        #expect(parsed?.arguments == ["Chromium", "--user-data-dir=/p", "about:blank"])
    }

    @Test func truncatedProcArgsAreRejected() {
        #expect(ProcessTable.parseProcArgs([1, 0]) == nil)
    }

    @Test func ownCommandLineIsReadable() {
        let own = ProcessTable.commandLine(of: ProcessInfo.processInfo.processIdentifier)
        #expect(own?.executable.isEmpty == false)
        #expect(own?.arguments.isEmpty == false)
    }
}

/// P: start to ready with a real browser (skipped when none is installed); the browser is stopped.
final class BrowserSessionPerformanceTests: XCTestCase {
    func testStartToReady() throws {
        guard (try? BrowserLaunch.resolve(explicit: nil)) != nil else { throw XCTSkip("No Chromium-family browser installed") }
        let profile = FileManager.default.temporaryDirectory.appending(path: "alethe-browser-perf-\(UUID().uuidString)",
                                                                        directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: profile) }
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric()], options: options) {
            let session = BrowserSession(profileDirectory: profile)
            let done = expectation(description: "ready and stopped")
            Task {
                let info = try? await session.start(headless: true)
                XCTAssertNotNil(info)
                XCTAssertEqual(session.current, info)
                await session.stop()
                XCTAssertNil(session.current)
                done.fulfill()
            }
            wait(for: [done], timeout: 30)
        }
    }
}
