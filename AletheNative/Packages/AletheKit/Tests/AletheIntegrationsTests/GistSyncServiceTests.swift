import AletheFoundation
import AletheModel
import Foundation
import Synchronization
import Testing
@testable import AletheIntegrations

/// Answers requests of sessions tagged with `X-Gist-Stub` through that stub's handler; never the network.
final class GistStubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Gist-Stub"
    static let stubs = Mutex<[String: GistStub]>([:])

    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: header) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header),
              let stub = Self.stubs.withLock({ $0[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var recorded = request
        recorded.httpBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let (status, body) = stub.answer(recorded)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class LogLines: Sendable {
    let lines = Mutex<[String]>([])
}

/// A fake GitHub: routes by "METHOD path" and records every request.
final class GistStub: Sendable {
    typealias Route = @Sendable (URLRequest) -> (Int, Data)

    let id = UUID().uuidString
    private let routes: Mutex<[String: Route]>
    private let log = Mutex<[URLRequest]>([])

    init(_ routes: [String: Route]) {
        self.routes = Mutex(routes)
        GistStubProtocol.stubs.withLock { $0[id] = self }
    }

    deinit { GistStubProtocol.stubs.withLock { $0[id] = nil } }

    var requests: [URLRequest] { log.withLock { $0 } }
    var calls: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url?.path() ?? "")" } }

    func answer(_ request: URLRequest) -> (Int, Data) {
        log.withLock { $0.append(request) }
        let key = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
        guard let route = routes.withLock({ $0[key] }) else { return (500, Data()) }
        return route(request)
    }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GistStubProtocol.self]
        configuration.httpAdditionalHeaders = [GistStubProtocol.header: id]
        return URLSession(configuration: configuration)
    }

    static func json(_ status: Int, _ object: Any) -> (Int, Data) {
        (status, try! JSONSerialization.data(withJSONObject: object))
    }
}

/// Unit tests over a `URLProtocol` stub (P7-11). No upstream golden cases exist for `github_sync.rs`.
@Suite(.timeLimit(.minutes(1))) struct GistSyncServiceTests {
    static let token = "ghp_FIXTUREGISTTOKEN000000000000000000"
    static let profile = ProfileID(rawValue: "default")

    struct Fixture {
        let locations: DataLocations
        let secrets = InMemorySecretStore()
        let logs = LogLines()
        let stub: GistStub

        init(_ routes: [String: GistStub.Route], connected: Bool = true, state: GistSyncState? = nil) throws {
            locations = DataLocations(root: FileManager.default.temporaryDirectory
                .appending(path: "alethe-gist-\(UUID().uuidString)", directoryHint: .isDirectory))
            stub = GistStub(routes)
            try FileManager.default.createDirectory(at: locations.profileDirectory(profile), withIntermediateDirectories: true)
            if connected { try secrets.setString(GistSyncServiceTests.token, for: .githubToken, profile: profile.rawValue) }
            if let state { try state.write(to: locations.gistSync(profile)) }
        }

        var profile: ProfileID { GistSyncServiceTests.profile }

        func service() -> GistSyncService {
            GistSyncService(profile: profile, locations: locations, secrets: secrets, session: stub.session,
                            now: { Date(timeIntervalSince1970: 1_767_225_600) },
                            log: { [logs] message in logs.lines.withLock { $0.append(message) } })
        }

        var state: GistSyncState { GistSyncState.load(from: locations.gistSync(profile)) }

        func write(_ name: String, _ text: String) throws {
            try Data(text.utf8).write(to: locations.profileDirectory(profile).appending(path: name))
        }

        func read(_ name: String) -> String? {
            try? String(contentsOf: locations.profileDirectory(profile).appending(path: name), encoding: .utf8)
        }

        /// The token is in no file under the data root and in no log line.
        func expectTokenNowhere() throws {
            #expect(!logs.lines.withLock { $0 }.contains { $0.contains(GistSyncServiceTests.token) })
            let enumerator = FileManager.default.enumerator(at: locations.root, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                #expect(!text.contains(GistSyncServiceTests.token), "\(url.lastPathComponent) holds the token")
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: locations.root) }
    }

    static func workspaceJSON(projects: [String] = ["remote-project"]) async throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "gist-workspace-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = WorkspaceDocument(projects: projects.map { Project(name: $0, folder: "/tmp/\($0)") })
        try await DocumentStore<WorkspaceDocument>(url: url).save(document, revision: 1)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func preferencesJSON() async throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: "gist-preferences-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try await DocumentStore<PreferencesDocument>(url: url).save(PreferencesDocument(), revision: 1)
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func gist(_ id: String, files: [String: [String: Any]]) -> (Int, Data) {
        GistStub.json(200, ["id": id, "files": files])
    }

    static func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    // MARK: - Token

    @Test func invalidTokenIsRefusedAndNotStored() async throws {
        let fixture = try Fixture(["GET /user": { _ in GistStub.json(401, ["message": "Bad credentials"]) }], connected: false)
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.invalidToken) { try await fixture.service().connect(token: Self.token) }
        #expect(try fixture.secrets.string(for: .githubToken, profile: fixture.profile.rawValue) == nil)
        #expect(try await fixture.service().status().connected == false)
    }

    @Test func emptyTokenIsRefusedWithoutARequest() async throws {
        let fixture = try Fixture([:], connected: false)
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.emptyToken) { try await fixture.service().connect(token: "  \n") }
        #expect(fixture.stub.requests.isEmpty)
    }

    @Test func connectKeepsTheTokenInTheKeychainAndTheLoginInTheState() async throws {
        let fixture = try Fixture(["GET /user": { _ in GistStub.json(200, ["login": "octo"]) }], connected: false)
        defer { fixture.cleanUp() }
        let status = try await fixture.service().connect(token: "  \(Self.token)\n")
        #expect(status.connected && status.login == "octo")
        #expect(try fixture.secrets.string(for: .githubToken, profile: fixture.profile.rawValue) == Self.token)
        #expect(fixture.state.login == "octo")

        let request = try #require(fixture.stub.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Alethe")
        try fixture.expectTokenNowhere()
    }

    @Test func disconnectDeletesTheTokenAndKeepsTheGist() async throws {
        let fixture = try Fixture([:], state: GistSyncState(login: "octo", gistID: "native"))
        defer { fixture.cleanUp() }
        let status = try await fixture.service().disconnect()
        #expect(!status.connected && status.login == nil && status.gistID == "native")
        #expect(try fixture.secrets.string(for: .githubToken, profile: fixture.profile.rawValue) == nil)
        await #expect(throws: GistSyncError.notConnected) { try await fixture.service().push() }
    }

    // MARK: - Push

    @Test func firstPushCreatesAPrivateGistWithTheSyncedFiles() async throws {
        let fixture = try Fixture(["POST /gists": { _ in GistStub.json(201, ["id": "created"]) }])
        defer { fixture.cleanUp() }
        try fixture.write("workspace.json", #"{"schemaVersion":2}"#)
        try fixture.write("preferences.json", #"{"schemaVersion":2}"#)
        try fixture.write("activity-stats.json", "  \n")
        try fixture.write("prompt-history.json", "[]")

        let status = try await fixture.service().push()
        #expect(status.gistID == "created" && status.lastPushAt == Date(timeIntervalSince1970: 1_767_225_600))
        #expect(fixture.stub.calls == ["POST /gists"])
        let body = Self.body(try #require(fixture.stub.requests.first))
        #expect(body["public"] as? Bool == false)
        #expect(body["description"] as? String == GistSyncService.gistDescription)
        let files = try #require(body["files"] as? [String: [String: String]])
        #expect(Set(files.keys) == ["workspace.json", "preferences.json"], "blank and unsynced files stay home")
        #expect(files["workspace.json"]?["content"] == #"{"schemaVersion":2}"#)
        try fixture.expectTokenNowhere()
    }

    @Test func laterPushPatchesTheKnownGist() async throws {
        let fixture = try Fixture(["PATCH /gists/native": { _ in GistStub.json(200, ["id": "native"]) }],
                                  state: GistSyncState(login: "octo", gistID: "native"))
        defer { fixture.cleanUp() }
        try fixture.write("workspace.json", #"{"schemaVersion":2}"#)
        let status = try await fixture.service().push()
        #expect(fixture.stub.calls == ["PATCH /gists/native"])
        #expect(status.gistID == "native" && fixture.state.login == "octo")
    }

    @Test(arguments: [404, 422]) func aGoneGistIsRecreated(status: Int) async throws {
        let fixture = try Fixture(["PATCH /gists/gone": { _ in GistStub.json(status, ["message": "Not Found"]) },
                                   "POST /gists": { _ in GistStub.json(201, ["id": "fresh"]) }],
                                  state: GistSyncState(gistID: "gone"))
        defer { fixture.cleanUp() }
        try fixture.write("workspace.json", #"{"schemaVersion":2}"#)
        let pushed = try await fixture.service().push()
        #expect(fixture.stub.calls == ["PATCH /gists/gone", "POST /gists"])
        #expect(pushed.gistID == "fresh" && fixture.state.gistID == "fresh")
    }

    @Test func theTauriGistIsNeverPushedTo() async throws {
        let fixture = try Fixture(["POST /gists": { _ in GistStub.json(201, ["id": "native"]) }],
                                  state: GistSyncState(gistID: "tauri", tauriGistID: "tauri"))
        defer { fixture.cleanUp() }
        try fixture.write("workspace.json", #"{"schemaVersion":2}"#)
        let status = try await fixture.service().push()
        #expect(fixture.stub.calls == ["POST /gists"])
        #expect(status.gistID == "native" && status.tauriGistID == "tauri")
    }

    @Test func pushErrors() async throws {
        let fixture = try Fixture(["POST /gists": { _ in GistStub.json(500, [:]) }])
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.nothingToSync) { try await fixture.service().push() }
        try fixture.write("workspace.json", #"{"schemaVersion":2}"#)
        await #expect(throws: GistSyncError.http(500)) { try await fixture.service().push() }
        #expect(fixture.state.gistID == nil && fixture.state.lastPushAt == nil)
    }

    // MARK: - Pull

    @Test func pullStagesAValidatedProfileWithoutChangingIt() async throws {
        let remote = try await Self.workspaceJSON(projects: ["one", "two"])
        let preferences = try await Self.preferencesJSON()
        let fixture = try Fixture(["GET /gists/native": { _ in
            Self.gist("native", files: ["workspace.json": ["content": remote, "truncated": false],
                                        "preferences.json": ["content": preferences]])
        }], state: GistSyncState(login: "octo", gistID: "native"))
        defer { fixture.cleanUp() }
        let local = try await Self.workspaceJSON(projects: ["local"])
        try fixture.write("workspace.json", local)
        try FileManager.default.createDirectory(at: fixture.locations.scrollback(fixture.profile), withIntermediateDirectories: true)
        try Data("scroll".utf8).write(to: fixture.locations.scrollback(fixture.profile).appending(path: "tab.bin"))

        let result = try await fixture.service().pull()
        guard case .replacesProfile(let staged) = result else { Issue.record("expected a profile pull"); return }
        #expect(staged.files == ["preferences.json", "workspace.json"])
        #expect(staged.projects == 2)
        #expect(staged.operation == .importProfile(fixture.profile, stagedFolder: staged.profileFolder.path))
        #expect(staged.profileFolder.path.hasPrefix(fixture.locations.importStaging.path))
        #expect(try String(contentsOf: staged.profileFolder.appending(path: "workspace.json"), encoding: .utf8) == remote)
        #expect(FileManager.default.fileExists(atPath: staged.profileFolder.appending(path: "scrollback/tab.bin").path))
        let stagedState = GistSyncState.load(from: staged.profileFolder.appending(path: GistSyncState.fileName))
        #expect(stagedState.lastPullAt == Date(timeIntervalSince1970: 1_767_225_600) && stagedState.gistID == "native")

        #expect(fixture.read("workspace.json") == local, "nothing changes before the relaunch")
        #expect(fixture.state.lastPullAt == nil)
        #expect(DataMaintenance.pending(in: fixture.locations) == nil, "scheduling is the app's call, after asking")

        fixture.service().discard(result)
        #expect(!FileManager.default.fileExists(atPath: staged.stagingRoot.path))
        try fixture.expectTokenNowhere()
    }

    @Test func aTruncatedFileIsReadFromItsRawURL() async throws {
        let remote = try await Self.workspaceJSON()
        let fixture = try Fixture([
            "GET /gists/native": { _ in
                Self.gist("native", files: ["workspace.json": ["content": String(remote.prefix(10)), "truncated": true,
                                                               "raw_url": "https://api.github.com/raw/native/workspace.json"]])
            },
            "GET /raw/native/workspace.json": { _ in (200, Data(remote.utf8)) },
        ], state: GistSyncState(gistID: "native"))
        defer { fixture.cleanUp() }
        let result = try await fixture.service().pull()
        guard case .replacesProfile(let staged) = result else { Issue.record("expected a profile pull"); return }
        #expect(fixture.stub.calls == ["GET /gists/native", "GET /raw/native/workspace.json"])
        #expect(try String(contentsOf: staged.profileFolder.appending(path: "workspace.json"), encoding: .utf8) == remote)
    }

    @Test func aRawURLOffGitHubIsRefused() async throws {
        let fixture = try Fixture(["GET /gists/native": { _ in
            Self.gist("native", files: ["workspace.json": ["truncated": true, "raw_url": "https://example.com/steal"]])
        }], state: GistSyncState(gistID: "native"))
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.malformedGist) { try await fixture.service().pull() }
        #expect(fixture.stub.calls == ["GET /gists/native"])
    }

    @Test func aMissingWorkspaceIsRefusedBeforeAnythingChanges() async throws {
        let fixture = try Fixture(["GET /gists/native": { _ in
            Self.gist("native", files: ["preferences.json": ["content": #"{"schemaVersion":2}"#]])
        }], state: GistSyncState(gistID: "native"))
        defer { fixture.cleanUp() }
        try fixture.write("preferences.json", #"{"schemaVersion":1}"#)
        await #expect(throws: GistSyncError.remoteMissingWorkspace) { try await fixture.service().pull() }
        #expect(fixture.read("preferences.json") == #"{"schemaVersion":1}"#)
        #expect(DataMaintenance.pending(in: fixture.locations) == nil)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.locations.importStaging.path)) ?? []).isEmpty)
        #expect(fixture.state.lastPullAt == nil)
    }

    @Test func anUndecodableWorkspaceIsRefused() async throws {
        let fixture = try Fixture(["GET /gists/native": { _ in
            Self.gist("native", files: ["workspace.json": ["content": #"{"schemaVersion":2,"projects":"nope"}"#]])
        }], state: GistSyncState(gistID: "native"))
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.invalidRemoteFile("workspace.json")) { try await fixture.service().pull() }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fixture.locations.importStaging.path)) ?? []).isEmpty)
    }

    @Test func aNewerWorkspaceIsRefused() async throws {
        let fixture = try Fixture(["GET /gists/native": { _ in
            Self.gist("native", files: ["workspace.json": ["content": #"{"schemaVersion":999}"#]])
        }], state: GistSyncState(gistID: "native"))
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.newerFormat) { try await fixture.service().pull() }
    }

    @Test func aTauriGistIsOfferedAsATauriImport() async throws {
        let projects = #"{"version":9,"groups":[],"projects":[]}"#
        let fixture = try Fixture(["GET /gists/tauri": { _ in
            Self.gist("tauri", files: ["projects.json": ["content": projects],
                                       "activity-stats.json": ["content": "{}"]])
        }], state: GistSyncState(login: "octo", tauriGistID: "tauri"))
        defer { fixture.cleanUp() }
        let result = try await fixture.service().pull()
        guard case .tauriImport(let pull) = result else { Issue.record("expected a Tauri import"); return }
        #expect(try String(contentsOf: pull.projectsFile, encoding: .utf8) == projects)
        #expect(fixture.state.gistID == nil, "pulling the Tauri gist never makes it the push target")
        fixture.service().discard(result)
        #expect(!FileManager.default.fileExists(atPath: pull.stagingRoot.path))
    }

    @Test func pullErrors() async throws {
        let fixture = try Fixture(["GET /gists/gone": { _ in GistStub.json(404, [:]) }])
        defer { fixture.cleanUp() }
        await #expect(throws: GistSyncError.noRemote) { try await fixture.service().pull() }
        try GistSyncState(gistID: "gone").write(to: fixture.locations.gistSync(fixture.profile))
        await #expect(throws: GistSyncError.noRemote) { try await fixture.service().pull() }
    }
}
