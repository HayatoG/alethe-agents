import Foundation

// Port of upstream `mcp_catalog.rs`: the official MCP registry searched with cursor paging, entries
// mapped to runnable install options, and the first page of each query cached for the offline case.

/// An environment variable (or HTTP header) the server expects.
public struct McpEnvHint: Hashable, Sendable, Codable {
    public var name: String
    public var description: String?
    public var `default`: String?
    public var secret: Bool
    public var required: Bool

    public init(name: String, description: String? = nil, default: String? = nil, secret: Bool = false,
                required: Bool = false) {
        self.name = name
        self.description = description
        self.default = `default`
        self.secret = secret
        self.required = required
    }
}

public enum McpInstallKind: String, Hashable, Sendable, Codable {
    case stdio
    case http
    case sse
}

public struct McpInstallOption: Hashable, Sendable, Codable {
    public var kind: McpInstallKind
    public var label: String
    public var command: String?
    public var args: [String]
    public var url: String?
    public var env: [McpEnvHint]
    public var headers: [McpEnvHint]

    public init(kind: McpInstallKind, label: String, command: String? = nil, args: [String] = [], url: String? = nil,
                env: [McpEnvHint] = [], headers: [McpEnvHint] = []) {
        self.kind = kind
        self.label = label
        self.command = command
        self.args = args
        self.url = url
        self.env = env
        self.headers = headers
    }

    /// The server this option installs: env (stdio) or headers (remote) take `values` by name, else the
    /// hint's default; hints left without a value are omitted.
    public func server(named name: String, values: [String: String] = [:]) -> McpServer {
        func entries(_ hints: [McpEnvHint]) -> McpEnvMap {
            var map: McpEnvMap = [:]
            for hint in hints {
                if let value = values[hint.name] ?? hint.default, !value.isEmpty {
                    map[hint.name] = .literal(value)
                }
            }
            return map
        }
        switch kind {
        case .stdio:
            return McpServer(name: name, transport: .stdio(command: command ?? "", arguments: args, cwd: nil),
                             env: entries(env))
        case .http:
            return McpServer(name: name, transport: .http(url: url ?? "", headers: entries(headers)))
        case .sse:
            return McpServer(name: name, transport: .sse(url: url ?? "", headers: entries(headers)))
        }
    }
}

public struct McpCatalogEntry: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var suggestedName: String
    public var title: String
    public var description: String
    public var version: String
    public var repositoryUrl: String?
    public var installs: [McpInstallOption]
}

public struct McpRegistryPage: Hashable, Sendable, Codable {
    public var entries: [McpCatalogEntry]
    public var nextCursor: String?
    /// Set when the network failed and this page came from the on-disk copy fetched at that time.
    public var staleSince: Date?

    public init(entries: [McpCatalogEntry], nextCursor: String? = nil, staleSince: Date? = nil) {
        self.entries = entries
        self.nextCursor = nextCursor
        self.staleSince = staleSince
    }
}

public enum McpRegistryError: Error, Hashable, Sendable {
    case offline
    case status(Int)
    case malformed
    case cancelled
}

// MARK: - Parsing

public enum McpRegistryParser {
    private typealias Object = [String: Any]

    /// Upstream `page_from`: `{servers: [{server, _meta}], metadata: {nextCursor}}`; servers without an
    /// installable option are dropped.
    public static func page(from data: Data) -> McpRegistryPage? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return page(from: body)
    }

    static func page(from body: [String: Any]) -> McpRegistryPage {
        let entries = (body["servers"] as? [Any] ?? []).compactMap { raw -> McpCatalogEntry? in
            guard let item = raw as? Object, let server = item["server"] as? Object else { return nil }
            return entry(from: server, meta: item["_meta"] as? Object)
        }
        return McpRegistryPage(entries: entries, nextCursor: text(body["metadata"] as? Object, "nextCursor"))
    }

    public static func entry(from data: Data) -> McpCatalogEntry? {
        guard let server = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return entry(from: server, meta: nil)
    }

    static func entry(from server: [String: Any], meta: [String: Any]?) -> McpCatalogEntry? {
        guard let id = text(server, "name") else { return nil }
        let provided = meta?["io.modelcontextprotocol.registry/publisher-provided"] as? Object
        let title = text(provided, "title") ?? text(server, "title") ?? id
        let installs = objects(server["remotes"]).compactMap(remoteInstall)
            + objects(server["packages"]).compactMap(packageInstall)
        guard !installs.isEmpty else { return nil }
        return McpCatalogEntry(
            id: id,
            suggestedName: suggestedName(id),
            title: title,
            description: text(server, "description") ?? "",
            version: text(server, "version") ?? "",
            repositoryUrl: text(server["repository"] as? Object, "url"),
            installs: installs
        )
    }

    /// Registry ids look like `com.pulsemcp/playwright-stealth`; agents want a short, filename-safe handle.
    public static func suggestedName(_ id: String) -> String {
        let tail = id.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "." }).last ?? Substring(id)
        let cleaned = String(String.UnicodeScalarView(tail.unicodeScalars.map { scalar in
            let safe = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
            return safe ? scalar : "-"
        }))
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
        return trimmed.isEmpty ? "mcp-server" : trimmed
    }

    private static func text(_ object: Object?, _ key: String) -> String? {
        guard let value = (object?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func objects(_ value: Any?) -> [Object] {
        (value as? [Any])?.compactMap { $0 as? Object } ?? []
    }

    private static func envHints(_ value: Any?) -> [McpEnvHint] {
        objects(value).compactMap { item in
            guard let name = text(item, "name") else { return nil }
            return McpEnvHint(
                name: name,
                description: text(item, "description"),
                default: text(item, "default"),
                secret: item["isSecret"] as? Bool ?? false,
                required: item["isRequired"] as? Bool ?? false
            )
        }
    }

    /// Registry arguments are either positional (`value`) or named (`name` plus optional `value`).
    private static func argumentValues(_ value: Any?) -> [String] {
        objects(value).flatMap { item -> [String] in
            let named = text(item, "name")
            let literal = text(item, "value") ?? text(item, "default")
            return [named, literal].compactMap { $0 }
        }
    }

    static func runtime(registryType: String, hint: String?) -> String? {
        switch hint {
        case "npx", "uvx", "docker", "dnx": return hint
        default:
            switch registryType {
            case "npm": return "npx"
            case "pypi": return "uvx"
            case "oci": return "docker"
            case "nuget": return "dnx"
            default: return nil
            }
        }
    }

    private static func packageInstall(_ package: Object) -> McpInstallOption? {
        guard let identifier = text(package, "identifier") else { return nil }
        let registryType = text(package, "registryType") ?? ""
        guard let runtime = runtime(registryType: registryType, hint: text(package, "runtimeHint")) else { return nil }
        // A package declaring a remote transport has no URL here: its `remotes` entry covers it.
        let transport = text(package["transport"] as? Object, "type") ?? "stdio"
        guard transport == "stdio" else { return nil }

        var args = argumentValues(package["runtimeArguments"])
        if registryType == "npm", let version = text(package, "version") {
            args.append("\(identifier)@\(version)")
        } else {
            args.append(identifier)
        }
        args += argumentValues(package["packageArguments"])
        return McpInstallOption(kind: .stdio, label: "\(runtime) \(identifier)", command: runtime, args: args,
                                env: envHints(package["environmentVariables"]))
    }

    private static func remoteInstall(_ remote: Object) -> McpInstallOption? {
        guard let url = text(remote, "url") else { return nil }
        let kind: McpInstallKind = text(remote, "type") == "sse" ? .sse : .http
        return McpInstallOption(kind: kind, label: url, url: url, headers: envHints(remote["headers"]))
    }
}

// MARK: - Search

/// Upstream `mcp_registry_search`. An actor, so cache reads and writes are serialized and run off the
/// main thread; the network call honors task cancellation and an 8 s timeout.
public actor McpRegistry {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoint = URL(string: "https://registry.modelcontextprotocol.io/v0/servers")!
    public static let requestTimeout: TimeInterval = 8
    public static let maxCachedQueries = 20
    public static let defaultLimit = 30

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout * 2
        return URLSession(configuration: configuration)
    }()

    /// The live network call: an ephemeral session with the request timeout.
    public static let urlSessionFetch: Fetch = { try await session.data(for: $0) }

    public nonisolated let cacheURL: URL
    private let fetch: Fetch
    private let now: @Sendable () -> Date
    private let userAgent: String

    public init(
        profileDirectory: URL,
        userAgent: String = McpRegistry.defaultUserAgent,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: @escaping Fetch = McpRegistry.urlSessionFetch
    ) {
        self.cacheURL = Self.cacheURL(profileDirectory: profileDirectory)
        self.userAgent = userAgent
        self.now = now
        self.fetch = fetch
    }

    public static var defaultUserAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Alethe/\($0)" } ?? "Alethe"
    }

    /// `<profile>/mcp/registry-cache.json`.
    public static func cacheURL(profileDirectory: URL) -> URL {
        profileDirectory.appending(path: "mcp", directoryHint: .isDirectory).appending(path: "registry-cache.json")
    }

    public static func request(query: String?, cursor: String?, limit: Int?, userAgent: String) -> URLRequest {
        var items = [
            URLQueryItem(name: "version", value: "latest"),
            URLQueryItem(name: "limit", value: String(min(max(limit ?? defaultLimit, 1), 100))),
        ]
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        if let cursor, !cursor.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        var request = URLRequest(url: endpoint.appending(queryItems: items), timeoutInterval: requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func cacheKey(_ query: String?) -> String {
        (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// One page of results. A first page fetched is cached under its query; when the network fails on a
    /// first page, the cached copy comes back with `staleSince` set. Later pages are never cached.
    public func search(query: String? = nil, cursor: String? = nil,
                       limit: Int? = nil) async throws(McpRegistryError) -> McpRegistryPage {
        let key = Self.cacheKey(query)
        let isFirstPage = cursor?.isEmpty ?? true
        let fetched: Result<McpRegistryPage, McpRegistryError>
        do {
            fetched = .success(try await fetchPage(query: query, cursor: cursor, limit: limit))
        } catch {
            fetched = .failure(error)
        }
        switch fetched {
        case .success(let page):
            if isFirstPage { store(page, for: key) }
            return page
        case .failure(let error):
            if error == .cancelled || !isFirstPage { throw error }
            guard let cached = readCache().queries[key] else { throw error }
            var page = cached.page
            page.staleSince = Date(timeIntervalSince1970: TimeInterval(cached.fetchedAt) / 1000)
            return page
        }
    }

    private func fetchPage(query: String?, cursor: String?, limit: Int?) async throws(McpRegistryError) -> McpRegistryPage {
        let request = Self.request(query: query, cursor: cursor, limit: limit, userAgent: userAgent)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw .cancelled
            }
            throw .offline
        }
        if Task.isCancelled { throw .cancelled }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .status(http.statusCode)
        }
        guard let page = McpRegistryParser.page(from: data) else { throw .malformed }
        return page
    }

    // MARK: Cache

    struct CachedPage: Codable {
        /// Milliseconds since 1970, as upstream stores it.
        var fetchedAt: UInt64
        var page: McpRegistryPage
    }

    struct Cache: Codable {
        var queries: [String: CachedPage] = [:]

        init(queries: [String: CachedPage] = [:]) { self.queries = queries }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            queries = try container.decodeIfPresent([String: CachedPage].self, forKey: .queries) ?? [:]
        }
    }

    func readCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return Cache() }
        return cache
    }

    private func store(_ page: McpRegistryPage, for key: String) {
        var cache = readCache()
        let millis = UInt64(max(0, now().timeIntervalSince1970 * 1000))
        cache.queries[key] = CachedPage(fetchedAt: millis, page: page)
        while cache.queries.count > Self.maxCachedQueries,
              let oldest = cache.queries.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key {
            cache.queries[oldest] = nil
        }
        // Best effort, like upstream: a cache that cannot be written only costs the offline fallback.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
