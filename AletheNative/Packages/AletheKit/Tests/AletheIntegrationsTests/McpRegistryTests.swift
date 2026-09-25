import Foundation
import Testing
@testable import AletheIntegrations

// Golden cases from upstream `mcp_catalog.rs`.
private let packageServer = #"""
{
  "name": "com.pulsemcp/playwright-stealth",
  "description": "Browser automation using Playwright.",
  "version": "0.2.3",
  "repository": { "url": "https://github.com/pulsemcp/mcp-servers", "source": "github" },
  "packages": [
    {
      "registryType": "npm",
      "identifier": "playwright-stealth-mcp-server",
      "version": "0.2.3",
      "runtimeHint": "npx",
      "transport": { "type": "stdio" },
      "runtimeArguments": [ { "value": "-y", "type": "positional" } ],
      "environmentVariables": [
        { "name": "PROXY_PASSWORD", "description": "Proxy password.", "isSecret": true },
        { "name": "HEADLESS", "default": "true" }
      ]
    }
  ]
}
"""#

private let remoteServer = #"""
{
  "name": "com.clauxel.guard/guard-mcp",
  "description": "Selector risk checks.",
  "version": "1.0.0",
  "remotes": [
    {
      "type": "streamable-http",
      "url": "https://guard.example.com/mcp",
      "headers": [ { "name": "Authorization", "description": "Bearer token." } ]
    }
  ]
}
"""#

private func entry(_ raw: String) throws -> McpCatalogEntry {
    try #require(McpRegistryParser.entry(from: Data(raw.utf8)))
}

private func pageBody(cursor: String? = "abc:1.0") -> Data {
    let metadata = cursor.map { #","metadata":{"nextCursor":"\#($0)"}"# } ?? ""
    return Data(#"{"servers":[{"server":\#(packageServer)},{"server":{"name":"x/y"}}]\#(metadata)}"#.utf8)
}

@Suite struct McpRegistryParserTests {
    @Test func anNpmPackageBecomesARunnableNpxCommand() throws {
        let entry = try entry(packageServer)
        #expect(entry.suggestedName == "playwright-stealth")
        #expect(entry.title == "com.pulsemcp/playwright-stealth")
        #expect(entry.repositoryUrl == "https://github.com/pulsemcp/mcp-servers")
        #expect(entry.installs.count == 1)
        let install = entry.installs[0]
        #expect(install.kind == .stdio)
        #expect(install.command == "npx")
        #expect(install.args == ["-y", "playwright-stealth-mcp-server@0.2.3"])
        #expect(install.label == "npx playwright-stealth-mcp-server")
    }

    @Test func environmentHintsCarryTheSecretFlag() throws {
        let install = try entry(packageServer).installs[0]
        let secret = try #require(install.env.first { $0.name == "PROXY_PASSWORD" })
        #expect(secret.secret)
        let plain = try #require(install.env.first { $0.name == "HEADLESS" })
        #expect(!plain.secret)
        #expect(plain.default == "true")
    }

    @Test func aRemoteBecomesAnHTTPOptionWithItsHeaders() throws {
        let install = try entry(remoteServer).installs[0]
        #expect(install.kind == .http)
        #expect(install.url == "https://guard.example.com/mcp")
        #expect(install.headers.map(\.name) == ["Authorization"])
        #expect(install.command == nil)
    }

    @Test func anSSERemoteKeepsItsKind() throws {
        let raw = #"{"name":"a/b","remotes":[{"type":"sse","url":"https://x.test/sse"}]}"#
        #expect(try entry(raw).installs.first?.kind == .sse)
    }

    @Test func registryTypesMapToRuntimes() throws {
        #expect(McpRegistryParser.runtime(registryType: "npm", hint: nil) == "npx")
        #expect(McpRegistryParser.runtime(registryType: "pypi", hint: nil) == "uvx")
        #expect(McpRegistryParser.runtime(registryType: "oci", hint: nil) == "docker")
        #expect(McpRegistryParser.runtime(registryType: "nuget", hint: nil) == "dnx")
        #expect(McpRegistryParser.runtime(registryType: "mcpb", hint: nil) == nil)
        #expect(McpRegistryParser.runtime(registryType: "npm", hint: "docker") == "docker")
        // Only npm packages get a pinned `@version`.
        let pypi = #"{"name":"a/b","packages":[{"registryType":"pypi","identifier":"srv","version":"1.2"}]}"#
        #expect(try entry(pypi).installs.first?.args == ["srv"])
    }

    @Test func namedArgumentsKeepNameThenValue() throws {
        let raw = #"""
        {"name":"a/b","packages":[{"registryType":"oci","identifier":"img","runtimeArguments":[
          {"type":"named","name":"--rm"},{"type":"named","name":"-e","value":"X=1"}],
          "packageArguments":[{"type":"positional","default":"serve"}]}]}
        """#
        #expect(try entry(raw).installs.first?.args == ["--rm", "-e", "X=1", "img", "serve"])
    }

    @Test func aPackageWithARemoteTransportIsLeftToItsRemote() throws {
        let raw = #"{"name":"a/b","packages":[{"registryType":"npm","identifier":"p","transport":{"type":"streamable-http"}}]}"#
        #expect(McpRegistryParser.entry(from: Data(raw.utf8)) == nil)
    }

    @Test func aServerWithNoInstallableOptionIsDropped() {
        #expect(McpRegistryParser.entry(from: Data(#"{"name":"x/y","version":"1"}"#.utf8)) == nil)
    }

    @Test func publisherProvidedTitleWins() throws {
        let body = #"{"servers":[{"server":\#(remoteServer),"_meta":{"io.modelcontextprotocol.registry/publisher-provided":{"title":"Guard"}}}]}"#
        let page = try #require(McpRegistryParser.page(from: Data(body.utf8)))
        #expect(page.entries.first?.title == "Guard")
    }

    @Test func suggestedNamesStayFilenameSafe() {
        #expect(McpRegistryParser.suggestedName("com.pulsemcp/playwright-stealth") == "playwright-stealth")
        #expect(McpRegistryParser.suggestedName("ac.inference.sh/mcp") == "mcp")
        #expect(McpRegistryParser.suggestedName("weird name!!") == "weird-name")
        #expect(McpRegistryParser.suggestedName("///") == "mcp-server")
    }

    @Test func aPageKeepsItsCursorAndSkipsUnusableServers() throws {
        let page = try #require(McpRegistryParser.page(from: pageBody()))
        #expect(page.entries.count == 1)
        #expect(page.nextCursor == "abc:1.0")
        #expect(page.staleSince == nil)
    }

    @Test func installOptionsBecomeServersWithHintValues() throws {
        let stdio = try entry(packageServer).installs[0].server(named: "pw", values: ["PROXY_PASSWORD": "hunter2"])
        #expect(stdio.transport == .stdio(command: "npx", arguments: ["-y", "playwright-stealth-mcp-server@0.2.3"], cwd: nil))
        #expect(stdio.env == ["PROXY_PASSWORD": .literal("hunter2"), "HEADLESS": .literal("true")])

        let remote = try entry(remoteServer).installs[0].server(named: "guard")
        #expect(remote.transport == .http(url: "https://guard.example.com/mcp", headers: [:]))
    }
}

@Suite struct McpRegistrySearchTests {
    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [URLRequest] = []
        func append(_ request: URLRequest) { lock.withLock { items.append(request) } }
        var all: [URLRequest] { lock.withLock { items } }
    }

    private func temporaryProfile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "McpRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func ok(_ data: Data) -> McpRegistry.Fetch {
        { request in (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
    }

    private static let offline: McpRegistry.Fetch = { _ in throw URLError(.notConnectedToInternet) }

    @Test func requestCarriesQueryCursorAndClampedLimit() throws {
        let request = McpRegistry.request(query: "  play ", cursor: "c:1", limit: 500, userAgent: "Alethe/2")
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.host == "registry.modelcontextprotocol.io")
        #expect(components.path == "/v0/servers")
        #expect(components.queryItems == [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "search", value: "play"),
            URLQueryItem(name: "cursor", value: "c:1"),
        ])
        #expect(request.timeoutInterval == 8)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Alethe/2")

        let bare = McpRegistry.request(query: " ", cursor: "", limit: 0, userAgent: "Alethe")
        let items = URLComponents(url: try #require(bare.url), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "version", value: "latest"), URLQueryItem(name: "limit", value: "1")])
    }

    @Test func aFirstPageIsCachedAndServedStaleWhenOffline() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let online = McpRegistry(profileDirectory: profile, now: { fetchedAt }, fetch: Self.ok(pageBody()))
        let fresh = try await online.search(query: "Play")
        #expect(fresh.entries.count == 1)
        #expect(FileManager.default.fileExists(atPath: McpRegistry.cacheURL(profileDirectory: profile).path))

        let disconnected = McpRegistry(profileDirectory: profile, fetch: Self.offline)
        let stale = try await disconnected.search(query: " play ")
        #expect(stale.entries == fresh.entries)
        #expect(stale.staleSince == fetchedAt)

        await #expect(throws: McpRegistryError.offline) { try await disconnected.search(query: "other") }
    }

    @Test func laterPagesAreNeitherCachedNorServedFromCache() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let online = McpRegistry(profileDirectory: profile, fetch: Self.ok(pageBody(cursor: nil)))
        _ = try await online.search(query: "q", cursor: "next")
        #expect(await online.readCache().queries.isEmpty)

        _ = try await online.search(query: "q")
        let disconnected = McpRegistry(profileDirectory: profile, fetch: Self.offline)
        await #expect(throws: McpRegistryError.offline) { try await disconnected.search(query: "q", cursor: "next") }
    }

    @Test func theCacheKeepsTheNewestTwentyQueries() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let clock = Clock()
        let registry = McpRegistry(profileDirectory: profile, now: { clock.tick() }, fetch: Self.ok(pageBody()))
        for index in 0..<25 { _ = try await registry.search(query: "q\(index)") }
        let keys = Set(await registry.readCache().queries.keys)
        #expect(keys.count == McpRegistry.maxCachedQueries)
        #expect(!keys.contains("q0"))
        #expect(keys.contains("q24"))
    }

    @Test func statusAndMalformedBodiesAreErrors() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let failing = McpRegistry(profileDirectory: profile, fetch: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: McpRegistryError.status(503)) { try await failing.search(cursor: "x") }

        let garbled = McpRegistry(profileDirectory: profile, fetch: Self.ok(Data("<html>".utf8)))
        await #expect(throws: McpRegistryError.malformed) { try await garbled.search(cursor: "x") }
    }

    @Test func cancellationIsNotAnsweredFromTheCache() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        _ = try await McpRegistry(profileDirectory: profile, fetch: Self.ok(pageBody())).search(query: "q")
        let cancelled = McpRegistry(profileDirectory: profile, fetch: { _ in throw CancellationError() })
        await #expect(throws: McpRegistryError.cancelled) { try await cancelled.search(query: "q") }
    }

    @Test func requestsGoThroughTheInjectedFetch() async throws {
        let profile = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: profile) }
        let requests = Requests()
        let registry = McpRegistry(profileDirectory: profile, userAgent: "Alethe/test", fetch: { request in
            requests.append(request)
            return (pageBody(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = try await registry.search(query: "a", limit: 5)
        #expect(requests.all.count == 1)
        #expect(requests.all.first?.value(forHTTPHeaderField: "User-Agent") == "Alethe/test")
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: TimeInterval = 1_700_000_000
        func tick() -> Date { lock.withLock { seconds += 1; return Date(timeIntervalSince1970: seconds) } }
    }
}
