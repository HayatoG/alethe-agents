import Foundation
import Testing
@testable import AletheRemote

/// Upstream `remote/appearance.rs` test.
struct RemoteClientBundleGoldenTests {
    @Test func selectedBrandIconUsesEmbeddedPNGAssets() async throws {
        let bundle = RemoteClientBundle()
        let blush = try #require(await bundle.asset(at: "/brand-icon.png", appIconTheme: "elite-blush"))
        let indigo = try #require(await bundle.asset(at: "/brand-icon.png", appIconTheme: "elite-indigo"))

        #expect(blush.data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(blush.data != indigo.data)
    }
}

struct RemoteClientBundleTests {
    let bundle = RemoteClientBundle()

    private func text(_ path: String) async throws -> String {
        let asset = try #require(await bundle.asset(at: path, appIconTheme: "elite-indigo"))
        return String(decoding: asset.data, as: UTF8.self)
    }

    /// Absolute static paths in a file (`"/app.css"`, `'/assets/agents/claude.png'`), skipping the API.
    private func staticPaths(in source: String) -> Set<String> {
        let pattern = /["'`](\/[A-Za-z0-9._\/-]+\.[A-Za-z0-9]+)/
        return Set(source.matches(of: pattern).map { String($0.output.1) })
            .filter { !$0.hasPrefix("/api/") && $0 != "/appearance.json" }
    }

    @Test func everyPathIndexAndAppRequestResolves() async throws {
        let index = try await text("/index.html")
        let app = try await text("/app.js")
        let theme = try await text("/theme.css")
        var paths = staticPaths(in: index).union(staticPaths(in: app))
        // theme.css loads its fonts relative to /theme.css.
        for match in theme.matches(of: /url\('\.\.(\/assets\/fonts\/[^']+)'\)/) {
            paths.insert(String(match.output.1))
        }

        #expect(paths.isSuperset(of: [
            "/manifest.webmanifest", "/brand-icon.png", "/theme.css", "/vendor/xterm.css", "/app.css",
            "/vendor/xterm.js", "/vendor/addon-unicode11.js", "/app.js", "/assets/agents/claude.png",
            "/assets/fonts/CaskaydiaCoveNerdFontMono-Regular.ttf",
        ]))
        for path in paths {
            let asset = await bundle.asset(at: path, appIconTheme: "elite-indigo")
            #expect(asset != nil, "\(path) does not resolve")
            #expect(asset?.data.isEmpty == false, "\(path) is empty")
        }
        // app.js imports its locales relative to itself.
        #expect(app.contains("from './locales.js'"))
        #expect(await bundle.asset(at: "/locales.js", appIconTheme: "elite-indigo") != nil)
    }

    @Test func everyRouteResolvesWithinTheStaticLimit() async throws {
        for path in RemoteClientBundle.routes.keys {
            let asset = try #require(await bundle.asset(at: path, appIconTheme: "elite-indigo"), "\(path)")
            #expect(!asset.response.exceedsLimit, "\(path)")
        }
    }

    @Test func contentTypesAndCachingFollowUpstream() async throws {
        let expected: [(String, String, RemoteResponse.Caching)] = [
            ("/", "text/html; charset=utf-8", .noStore),
            ("/app.js", "text/javascript; charset=utf-8", .noStore),
            ("/locales.js", "application/javascript; charset=utf-8", .noStore),
            ("/app.css", "text/css; charset=utf-8", .noStore),
            ("/theme.css", "text/css; charset=utf-8", .noStore),
            ("/manifest.webmanifest", "application/manifest+json", .noStore),
            ("/brand-icon.png", "image/png", .noStore),
            ("/vendor/xterm.js", "text/javascript; charset=utf-8", .immutable),
            ("/vendor/xterm.css", "text/css; charset=utf-8", .immutable),
            ("/vendor/addon-unicode11.js", "text/javascript; charset=utf-8", .immutable),
            ("/assets/agents/opencode.png", "image/png", .immutable),
            ("/assets/fonts/CaskaydiaCoveNerdFontMono-BoldItalic.ttf", "font/ttf", .immutable),
        ]
        for (path, contentType, caching) in expected {
            let asset = try #require(await bundle.asset(at: path, appIconTheme: "elite-indigo"), "\(path)")
            #expect(asset.contentType == contentType, "\(path)")
            #expect(asset.caching == caching, "\(path)")
        }
    }

    @Test func unknownPathsAndTraversalAreNotServed() async {
        for path in ["/bundle-manifest.json", "/vendor/LICENSE-xterm.txt", "/brand-icons/elite-blush.png",
                     "/../Info.plist", "/vendor/xterm.js.map", "/missing.js"] {
            #expect(await bundle.asset(at: path, appIconTheme: "elite-indigo") == nil, "\(path)")
        }
    }

    @Test func queryStringsAreIgnored() async {
        #expect(await bundle.asset(at: "/brand-icon.png?v=elite-blush", appIconTheme: "elite-blush") != nil)
    }

    @Test func unknownAppIconThemeFallsBackToTheDefaultBrandIcon() async throws {
        let unknown = try #require(await bundle.asset(at: "/brand-icon.png", appIconTheme: "missing-icon"))
        let indigo = try #require(await bundle.asset(at: "/brand-icon.png", appIconTheme: "elite-indigo"))
        #expect(unknown.data == indigo.data)
        for theme in RemoteClientBundle.brandIconThemes {
            #expect(RemoteClientBundle.brandIconFile(for: theme) == "brand-icons/\(theme).png")
        }
    }

    @Test func checksumsMatchTheManifest() throws {
        let manifest = try #require(bundle.manifest())
        #expect(manifest.upstreamSHA.count == 40)
        #expect(manifest.xterm.hasPrefix("5.5."))
        #expect(manifest.addonUnicode11.hasPrefix("0.9."))
        #expect(bundle.checksumMismatches().isEmpty)
        // Unpatched files are byte-identical to upstream; patched ones are listed with a patch.
        for entry in manifest.files where !entry.patched {
            #expect(entry.sha256 == entry.upstreamSHA256, "\(entry.path)")
        }
        #expect(manifest.files.contains(where: \.patched) == !manifest.patches.isEmpty)
    }

    @Test func manifestCoversEveryBundledFile() throws {
        let manifest = try #require(bundle.manifest())
        let listed = Set(manifest.files.map(\.path))
        for route in RemoteClientBundle.routes.values {
            if case .client(let path) = route.file { #expect(listed.contains(path), "\(path)") }
        }
        for theme in RemoteClientBundle.brandIconThemes {
            #expect(listed.contains(RemoteClientBundle.brandIconFile(for: theme)))
        }
        #expect(listed.isSuperset(of: ["vendor/LICENSE-xterm.txt", "vendor/LICENSE-addon-unicode11.txt"]))
    }
}
