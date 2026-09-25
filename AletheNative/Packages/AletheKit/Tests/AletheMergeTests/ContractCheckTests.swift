import Foundation
import Testing
@testable import AletheMerge

/// Golden ports of upstream `contract_check.rs` tests plus its pure helpers.
struct ContractCheckTests {
    func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("alethe-contract-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func write(_ dir: URL, _ name: String, _ text: String) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Upstream tests

    @Test func flagsCallWithNoMatchingRoute() throws {
        let root = try tempDir("mismatch")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "api.ts", "export function loadUsers() {\n  return fetch('/api/v2/users')\n}\n")
        try write(root, "server.js", "app.get('/api/v1/users', (req, res) => res.json([]))\n")
        let warnings = try ContractCheck.check(root: root)
        #expect(warnings.count == 1)
        #expect(warnings.first?.call.pathPattern == "/api/v2/users")
        #expect(warnings.first?.call.file == "api.ts")
        #expect(warnings.first?.call.line == 2)
        #expect(warnings.first?.reason == ContractCheck.reason(for: "/api/v2/users"))
    }

    @Test func doesNotFlagWhenRouteMatches() throws {
        let root = try tempDir("match")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "api.ts", "fetch('/api/users/' + id)\naxios.get('/api/users')\n")
        try write(root, "server.js", "app.get('/api/users/:id', handler)\nrouter.get('/api/users', handler)\n")
        #expect(try ContractCheck.check(root: root).isEmpty)
    }

    @Test func silentWhenNoBackendRoutesFound() throws {
        let root = try tempDir("nobackend")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "api.ts", "fetch('/whatever/not/real')\n")
        #expect(try ContractCheck.check(root: root).isEmpty)
    }

    @Test func ignoresAbsoluteExternalURLs() throws {
        let root = try tempDir("external")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "api.ts", "fetch('https://external.example.com/x')\n")
        try write(root, "server.js", "app.get('/api/x', handler)\n")
        #expect(try ContractCheck.check(root: root).isEmpty)
    }

    // MARK: Native additions

    @Test func missingDirectoryThrows() {
        #expect(throws: ContractCheckError.environmentNotFound) {
            try ContractCheck.check(root: URL(fileURLWithPath: "/nonexistent-\(UUID())"))
        }
    }

    @Test func skipsVendorFolders() throws {
        let root = try tempDir("skip")
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "node_modules/lib/index.js", "fetch('/nowhere/at/all')\n")
        try write(root, "src/server.ts", "router.post('/api/items', handler)\n")
        #expect(try ContractCheck.check(root: root).isEmpty)
    }

    @Test func normalizesParametersAndTrailingSlash() {
        #expect(ContractCheck.normalizePathPattern("/api/users/:id") == "/api/users/:param")
        #expect(ContractCheck.normalizePathPattern("/api/users/{user_id}") == "/api/users/:param")
        #expect(ContractCheck.normalizePathPattern("/api/users/<int:id>") == "/api/users/:param")
        #expect(ContractCheck.normalizePathPattern("/api/users/") == "/api/users")
        #expect(ContractCheck.normalizePathPattern("/") == "/")
    }

    @Test func relatedPaths() {
        #expect(ContractCheck.pathsRelated("/api/users", "/api/users"))
        #expect(ContractCheck.pathsRelated("/api/users/:param", "/api/users"))
        #expect(ContractCheck.pathsRelated("/api/users", "/api/users/:param"))
        #expect(ContractCheck.pathsRelated("/api/items/x", "/api/items/y"))
        #expect(!ContractCheck.pathsRelated("/api/v2/users", "/api/v1/users"))
        #expect(!ContractCheck.pathsRelated("", "/api"))
    }

    @Test func extractsMethodsAndFrameworks() {
        let calls = ContractCheck.calls(in: "axios.post(\"/api/login\", body)\nconst x = 1\nfetch(`/api/me`)", file: "a.ts")
        #expect(calls == [
            ApiCallSite(file: "a.ts", line: 1, method: "POST", pathPattern: "/api/login"),
            ApiCallSite(file: "a.ts", line: 3, method: nil, pathPattern: "/api/me"),
        ])
        let routes = ContractCheck.routes(in: "@app.get('/api/health')\nlet r = Router::new().route(\"/api/items\", get(list));", file: "m.py")
        #expect(routes.map(\.framework) == ["express", "fastapi", "axum"])
        #expect(routes.map(\.pathPattern) == ["/api/health", "/api/health", "/api/items"])
        #expect(routes.map(\.line) == [1, 1, 2])
    }
}
