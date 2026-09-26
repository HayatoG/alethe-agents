import AletheFoundation
@testable import AletheIntegrations
import AletheModel
import Foundation
import Testing
@testable import AletheRemote

/// The §10 security checklist for remote control and the loopback-only peripherals (P7-20), over the
/// package and app sources and the types that enforce each rule: nothing binds a wildcard address,
/// Tailscale fails closed, logs never carry tokens or message text, exports redact remote
/// credentials, saved documents never hold a token, and 9router and the Spotify OAuth callback stay
/// on 127.0.0.1. The source checks read the checkout this file was compiled from.
@Suite(.serialized)
struct RemoteSecurityChecklistTests {
    /// Its own port range, so it never competes with the transport and service tests.
    private static let configuration = RemoteTransport.Configuration(
        httpPorts: 9440...9450, webSocketPorts: 9441...9451, idleCheckInterval: .seconds(3600))

    private func makeService(lan: String, tailscale: String?) -> RemoteControlService {
        let hub = RemoteHub(resolver: RemoteHostResolver(lanAddress: { lan }, tailscaleAddress: { tailscale }))
        return RemoteControlService(hub: hub, terminals: FakeTerminals(), workspace: FakeWorkspace(),
                                    assets: FakeAssets(), configuration: Self.configuration)
    }

    // MARK: No wildcard bind

    @Test func wildcardAndNamedHostsAreNeverBindable() {
        for host in ["0.0.0.0", "::", "[::]", "", "*", "localhost", "example.com"] {
            #expect(RemoteTransport.bindableHost(host) == nil, "\(host) must not be bindable")
        }
        #expect(RemoteTransport.bindableHost("127.0.0.1") == "127.0.0.1")
        #expect(RemoteTransport.bindableHost("100.64.0.7") == "100.64.0.7")
    }

    @Test func aWildcardHostRefusesToStart() async {
        let service = makeService(lan: "0.0.0.0", tailscale: nil)
        let info = await service.setEnabled(true)
        #expect(!info.enabled)
        #expect(info.httpURL == nil && info.wsURL == nil)
        #expect(await nextEvent(service) == .startFailed)
        await service.stop()
    }

    @Test func everyListenerInTheSourcesBindsALiteralAddress() throws {
        let files = try SourceTree.swiftFiles()
        #expect(files.count > 50, "the checkout's sources were found")
        var listenerFiles = 0
        for file in files {
            let text = file.text
            if text.contains("NWListener(") {
                listenerFiles += 1
                // `NWListener(using:on:)` listens on every interface.
                #expect(!SourceTree.matches(#"NWListener\([^)]*\bon:"#, in: text), "\(file.name) binds a port on every interface")
                #expect(text.contains("requiredLocalEndpoint"), "\(file.name) creates a listener without a local endpoint")
            }
            for line in text.split(separator: "\n") where line.contains("requiredLocalEndpoint =") {
                let loopback = line.contains(#"host: "127.0.0.1""#)
                let remote = file.name == "RemoteTransport.swift" && line.contains("NWEndpoint.Host(host)")
                #expect(loopback || remote, "\(file.name): \(line.trimmingCharacters(in: .whitespaces))")
            }
            #expect(!text.contains("INADDR_ANY") && !text.contains("in6addr_any"), "\(file.name) uses a wildcard address")
            if SourceTree.matches(#"(?:Darwin\.)?\bbind\(\w+, "#, in: text) {
                #expect(text.contains(#"inet_addr("127.0.0.1")"#), "\(file.name) binds a socket off loopback")
            }
        }
        #expect(listenerFiles >= 3, "remote, hook server and Spotify callback listeners were checked")

        // The remote listeners bind only what `bindableHost` returned.
        let transport = try SourceTree.file("AletheRemote/RemoteTransport.swift")
        #expect(transport.contains("guard let bindHost = Self.bindableHost(host)"))
        let binds = SourceTree.count(#"await bind\(\s*host: (\w+)"#, in: transport)
        let boundToBindHost = SourceTree.count(#"await bind\(\s*host: bindHost"#, in: transport)
        #expect(binds == 2 && boundToBindHost == 2)
    }

    // MARK: Tailscale fails closed

    @Test func tailscaleMissingResolvesToAnUnbindableHost() async {
        let resolver = RemoteHostResolver(lanAddress: { "192.168.1.20" }, tailscaleAddress: { nil })
        #expect(await resolver.host(for: .tailscale) == "")
        #expect(await resolver.host(for: .lan) == "192.168.1.20")
        #expect(RemoteTransport.bindableHost("") == nil)
    }

    @Test func tailscaleMissingNeverFallsBackToTheLAN() async {
        let service = makeService(lan: "127.0.0.1", tailscale: nil)
        await service.apply(RemoteControlSettings(reachMode: .tailscale))
        let info = await service.setEnabled(true)
        #expect(!info.enabled)
        #expect(info.httpURL == nil, "no listener on the LAN address")
        #expect(await nextEvent(service) == .startFailed)
        await service.stop()
    }

    @Test func onlyCGNATAddressesCountAsTailscale() {
        for address in ["100.64.0.1", "100.100.100.100", "100.127.255.254"] {
            #expect(RemoteHost.isTailscaleRange(address))
        }
        for address in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "10.0.0.1", "0.0.0.0", "127.0.0.1", "", "fd7a::1"] {
            #expect(!RemoteHost.isTailscaleRange(address), "\(address) is not a Tailscale address")
        }
    }

    // MARK: No token in logs or exports

    @Test func remoteLogsNeverInterpolateTokensOrMessageText() throws {
        let files = try SourceTree.swiftFiles().filter {
            $0.path.contains("/Sources/AletheRemote/") || $0.path.contains("/Alethe/Remote/")
                || $0.name == "RemoteSettings.swift"
        }
        #expect(files.count >= 10)
        let forbidden = try NSRegularExpression(pattern: "(?i)token|pair|url|preview|text|message|body|input|name|payload|data")
        var calls = 0
        for file in files {
            #expect(!SourceTree.matches(#"(?<![\w.])(?:print|debugPrint|NSLog)\("#, in: file.text), "\(file.name) prints")
            for literal in SourceTree.logLiterals(in: file.text) {
                calls += 1
                for interpolation in SourceTree.interpolations(in: literal) {
                    if interpolation.contains("privacy: .private") { continue }
                    let expression = interpolation.components(separatedBy: ", privacy:").first ?? interpolation
                    if expression.hasSuffix(".count") { continue }
                    let range = NSRange(expression.startIndex..., in: expression)
                    #expect(forbidden.firstMatch(in: expression, range: range) == nil,
                            "\(file.name) logs \(expression) publicly")
                }
            }
        }
        #expect(calls >= 10, "the remote log calls were found")
    }

    @Test func exportsRedactRemoteCredentials() {
        let session = RemoteText.randomToken(length: RemoteLimits.sessionTokenLength)
        let pairing = RemoteText.randomToken(length: RemoteLimits.pairingTokenLength)
        let lines = [
            "GET /api/state Authorization: Bearer \(session)",
            #"{"sessionToken":"\#(session)","deviceId":1}"#,
            #"{"type":"hello","sessionToken":"\#(session)"}"#,
            "open http://192.168.1.20:9340/?pair=\(pairing) on the phone",
            "http://100.64.0.7:9340/?x=1&pair=\(pairing)",
        ]
        for line in lines {
            let redacted = SecretRedactor.redact(line)
            #expect(!redacted.contains(session) && !redacted.contains(pairing), "a remote token survived redaction")
            #expect(redacted.contains(SecretRedactor.placeholder))
        }
    }

    // MARK: No token in saved documents

    @Test func workspaceAndPreferencesNeverHoldRemoteTokens() throws {
        var workspace = WorkspaceDocument()
        let project = workspace.addProject(name: "remote", folder: "/tmp", color: .teal)
        let added = workspace.addPane(to: project, tab: PaneTab(agent: "claude", title: "shared"))
        let pane = try #require(added)
        workspace.setRemoteShared(pane, true)
        let workspaceKeys = try Self.keys(of: JSONEncoder().encode(workspace))
        #expect(workspaceKeys.contains("remoteShared"), "sharing is saved")
        #expect(workspaceKeys.allSatisfy { !$0.lowercased().contains("token") && !$0.lowercased().contains("pair") })

        var preferences = PreferencesDocument()
        preferences.remote = RemotePreferences(maxDevices: 4, readOnly: false, allowShellInput: true)
        let preferenceKeys = try Self.keys(of: JSONEncoder().encode(preferences))
        #expect(preferenceKeys.contains("remote"))
        #expect(preferenceKeys.allSatisfy { !$0.lowercased().contains("token") && !$0.lowercased().contains("pair") })

        // Tokens live in the hub only: the saved models never mention them.
        for file in try SourceTree.swiftFiles() where file.path.contains("/Sources/AletheModel/") {
            #expect(!file.text.contains("sessionToken") && !file.text.contains("pairingToken"), "\(file.name)")
        }
    }

    // MARK: Loopback-only peripherals

    @Test func router9ServesOnLoopbackOnly() throws {
        let paths = Router9Paths(profileDirectory: URL(filePath: "/p", directoryHint: .isDirectory))
        let managed = try Router9Launch.make(source: .managed, port: 20128, paths: paths, entryScriptExists: true,
                                             node: "/usr/bin/node", external: nil)
        let external = try Router9Launch.make(source: .external, port: 20128, paths: paths, entryScriptExists: false,
                                              node: nil, external: "/usr/local/bin/9router")
        for launch in [managed, external] {
            #expect(launch.environment["HOSTNAME"] == "127.0.0.1")
            #expect(launch.environment["NEXT_PUBLIC_BASE_URL"] == "http://127.0.0.1:20128")
        }
        #expect(Router9.baseURL(port: 20128).hasPrefix("http://127.0.0.1:"))
    }

    @Test func spotifyCallbackListensOnLoopbackOnly() throws {
        #expect(Spotify.redirectURI == "http://127.0.0.1:8888/callback")
        let loopback = try SourceTree.file("AletheIntegrations/Spotify/SpotifyLoopback.swift")
        #expect(loopback.contains(#"requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)"#))
        #expect(loopback.contains("allowLocalEndpointReuse = false"))
    }

    // MARK: Helpers

    /// Every key at any depth of a JSON document.
    private static func keys(of data: Data) throws -> Set<String> {
        func collect(_ value: Any, into keys: inout Set<String>) {
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    keys.insert(key)
                    collect(child, into: &keys)
                }
            } else if let array = value as? [Any] {
                for child in array { collect(child, into: &keys) }
            }
        }
        var keys = Set<String>()
        collect(try JSONSerialization.jsonObject(with: data), into: &keys)
        return keys
    }

    private func nextEvent(_ service: RemoteControlService, timeout: Duration = .seconds(5)) async -> RemoteEvent? {
        await withTaskGroup(of: RemoteEvent?.self) { group in
            group.addTask {
                for await event in service.events { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// The package's and the app's Swift sources, read from the checkout this test was built from.
private enum SourceTree {
    struct File {
        var path: String
        var name: String
        var text: String
    }

    /// `…/AletheKit/Tests/AletheRemoteTests/<this file>` → `…/AletheKit`.
    static let packageRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let appRoot = packageRoot.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Alethe")

    static func file(_ relativeToSources: String) throws -> String {
        try String(contentsOf: packageRoot.appending(path: "Sources").appending(path: relativeToSources), encoding: .utf8)
    }

    static func swiftFiles() throws -> [File] {
        var files: [File] = []
        for root in [packageRoot.appending(path: "Sources"), appRoot] {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                files.append(File(path: url.path, name: url.lastPathComponent, text: try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return files
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        count(pattern, in: text) > 0
    }

    static func count(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The string literal of every `logger.<level>("…")` call.
    static func logLiterals(in text: String) -> [String] {
        let pattern = #"logger\.(?:trace|debug|info|notice|warning|error|fault|critical|log)\("((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The contents of each `\( … )` in a literal, nested parentheses included.
    static func interpolations(in literal: String) -> [String] {
        var result: [String] = []
        var index = literal.startIndex
        while let start = literal.range(of: "\\(", range: index..<literal.endIndex) {
            var depth = 1
            var cursor = start.upperBound
            while cursor < literal.endIndex, depth > 0 {
                if literal[cursor] == "(" { depth += 1 }
                if literal[cursor] == ")" { depth -= 1 }
                if depth > 0 { cursor = literal.index(after: cursor) }
            }
            result.append(String(literal[start.upperBound..<cursor]))
            index = cursor < literal.endIndex ? literal.index(after: cursor) : cursor
        }
        return result
    }
}
