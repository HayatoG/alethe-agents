import Foundation
import Testing
@testable import AletheTerminal

@Suite struct LocalServerDetectorTests {
    @Test func findsDevServerAddressesOnce() {
        var detector = LocalServerDetector()
        let vite = "\u{1b}[32m  ➜  \u{1b}[1mLocal\u{1b}[22m:   \u{1b}[36mhttp://localhost:\u{1b}[1m5173\u{1b}[22m/\u{1b}[39m\n"
        #expect(detector.scan(Data(vite.utf8)) == [URL(string: "http://localhost:5173/")!])
        #expect(detector.scan(Data(vite.utf8)).isEmpty, "each address is offered once")
    }

    @Test func normalizesWildcardHostsAndTrailingPunctuation() {
        var detector = LocalServerDetector()
        let found = detector.scan(Data("Listening on http://0.0.0.0:8000. Also http://127.0.0.1:3000/app, done\n".utf8))
        #expect(found == [URL(string: "http://localhost:8000/")!, URL(string: "http://127.0.0.1:3000/app")!])
    }

    @Test func addressesSplitAcrossChunks() {
        var detector = LocalServerDetector()
        #expect(detector.scan(Data("ready at http://local".utf8)).isEmpty)
        #expect(detector.scan(Data("host:4321/docs\n".utf8)) == [URL(string: "http://localhost:4321/docs")!])
    }

    @Test func ignoresPublicAndPortlessAddresses() {
        var detector = LocalServerDetector()
        #expect(detector.scan(Data("see https://example.com:8080/x and http://localhost/ now\n".utf8)).isEmpty)
    }

    @Test func stripsOSCHyperlinks() {
        #expect(LocalServerDetector.stripEscapes("\u{1b}]8;;http://x\u{7}label\u{1b}]8;;\u{7}") == "label")
    }
}
