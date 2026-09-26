import AletheDesign
import CryptoKit
import Foundation

/// The upstream phone client (`src-tauri/remote/` plus the files its server embeds), bundled as
/// `Resources/RemoteClient` by `Scripts/sync-remote-client.sh` and served on upstream's paths with
/// its content types and caching (`remote/http.rs`). The copy is byte-identical to upstream except
/// the patches listed in `bundle-manifest.json`, so upstream's `src/remoteChat.test.ts` stays the
/// client's test. The Caskaydia fonts come from AletheDesign's resources.
public struct RemoteClientBundle: RemoteAssetSource {
    public enum File: Sendable, Equatable {
        /// A file under `RemoteClient/`.
        case client(String)
        /// A font file in AletheDesign's resources.
        case font(String)
        /// The brand icon of the app icon theme (`/brand-icon.png`).
        case brandIcon
    }

    public struct Route: Sendable, Equatable {
        public var file: File
        public var contentType: String
        public var caching: RemoteResponse.Caching
    }

    private static let html = "text/html; charset=utf-8"
    private static let javaScript = "text/javascript; charset=utf-8"
    private static let css = "text/css; charset=utf-8"

    /// Every path the client may request, as upstream `handle_static` answers it.
    public static let routes: [String: Route] = {
        var routes: [String: Route] = [
            "/": Route(file: .client("index.html"), contentType: html, caching: .noStore),
            "/index.html": Route(file: .client("index.html"), contentType: html, caching: .noStore),
            "/app.js": Route(file: .client("app.js"), contentType: javaScript, caching: .noStore),
            "/locales.js": Route(
                file: .client("locales.js"), contentType: "application/javascript; charset=utf-8", caching: .noStore
            ),
            "/app.css": Route(file: .client("app.css"), contentType: css, caching: .noStore),
            "/theme.css": Route(file: .client("theme.css"), contentType: css, caching: .noStore),
            "/manifest.webmanifest": Route(
                file: .client("manifest.webmanifest"), contentType: "application/manifest+json", caching: .noStore
            ),
            "/brand-icon.png": Route(file: .brandIcon, contentType: "image/png", caching: .noStore),
            "/vendor/xterm.js": Route(file: .client("vendor/xterm.js"), contentType: javaScript, caching: .immutable),
            "/vendor/xterm.css": Route(file: .client("vendor/xterm.css"), contentType: css, caching: .immutable),
            "/vendor/addon-unicode11.js": Route(
                file: .client("vendor/addon-unicode11.js"), contentType: javaScript, caching: .immutable
            ),
        ]
        for agent in ["claude", "codex", "opencode"] {
            routes["/assets/agents/\(agent).png"] = Route(
                file: .client("assets/agents/\(agent).png"), contentType: "image/png", caching: .immutable
            )
        }
        for style in ["Regular", "Bold", "Italic", "BoldItalic"] {
            let font = "CaskaydiaCoveNerdFontMono-\(style).ttf"
            routes["/assets/fonts/\(font)"] = Route(file: .font(font), contentType: "font/ttf", caching: .immutable)
        }
        return routes
    }()

    /// Upstream `is_known_app_icon`; anything else gets the default brand icon.
    public static let brandIconThemes = ["elite-original", "elite-pure-black", "elite-indigo", "elite-blush"]
    public static let defaultBrandIconTheme = "elite-indigo"

    public static func brandIconFile(for appIconTheme: String) -> String {
        let theme = brandIconThemes.contains(appIconTheme) ? appIconTheme : defaultBrandIconTheme
        return "brand-icons/\(theme).png"
    }

    /// The bundled `RemoteClient` directory.
    public let root: URL?

    /// `root` defaults to the bundled client.
    public init(root: URL? = nil) {
        self.root = root ?? Bundle.module.url(forResource: "RemoteClient", withExtension: nil)
    }

    public func asset(at path: String, appIconTheme: String) async -> RemoteAsset? {
        let path = path.firstIndex(of: "?").map { String(path[..<$0]) } ?? path
        guard let route = Self.routes[path],
              let url = fileURL(route.file, appIconTheme: appIconTheme),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return RemoteAsset(data: data, contentType: route.contentType, caching: route.caching)
    }

    public func fileURL(_ file: File, appIconTheme: String = defaultBrandIconTheme) -> URL? {
        switch file {
        case .client(let path): root?.appending(path: path)
        case .brandIcon: root?.appending(path: Self.brandIconFile(for: appIconTheme))
        case .font(let name): AletheFonts.bundledFontURL(named: name)
        }
    }

    // MARK: - Manifest

    /// `bundle-manifest.json`, written by the sync script.
    public struct Manifest: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            /// Path under `RemoteClient/`.
            public var path: String
            /// Upstream path (or `node_modules/<path>@<version>`).
            public var source: String
            public var upstreamSHA256: String
            /// The bundled file's checksum, after patches.
            public var sha256: String
            public var patched: Bool
        }

        public var upstreamSHA: String
        public var xterm: String
        public var addonUnicode11: String
        /// Patch files from `Scripts/remote-client-patches/`, in the order applied.
        public var patches: [String]
        public var files: [Entry]
    }

    public func manifest() -> Manifest? {
        guard let url = root?.appending(path: "bundle-manifest.json"), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// Manifest entries whose bundled bytes are missing or no longer match their checksum.
    public func checksumMismatches() -> [String] {
        guard let manifest = manifest(), let root else { return ["bundle-manifest.json"] }
        return manifest.files.compactMap { entry in
            guard let data = try? Data(contentsOf: root.appending(path: entry.path)) else { return entry.path }
            return Self.sha256(data) == entry.sha256 ? nil : entry.path
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
