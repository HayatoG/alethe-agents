import Foundation
import Testing
import XCTest
@testable import AletheTerminal

@Suite struct ScrollbackFileTests {
    private func file(cap: Int = 1024) -> (ScrollbackFile, URL) {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "alethe-scrollback-\(UUID().uuidString)/tab.bin")
        return (ScrollbackFile(url: url, cap: cap, flushInterval: .milliseconds(20)), url)
    }

    @Test func appendsAreBatchedAndLoadable() {
        let (scrollback, url) = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(scrollback.load().isEmpty)
        scrollback.append(Data("one ".utf8))
        scrollback.append(Data("two".utf8))
        scrollback.flush()
        #expect(String(decoding: scrollback.load(), as: UTF8.self) == "one two")
    }

    @Test func writesWithoutAnExplicitFlush() async throws {
        let (scrollback, url) = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        scrollback.append(Data("later".utf8))
        try await Task.sleep(for: .milliseconds(300))
        #expect((try? Data(contentsOf: url)) == Data("later".utf8))
    }

    @Test func compactsPastTwiceTheCapAndLoadsOnlyTheTail() throws {
        let (scrollback, url) = file(cap: 100)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for index in 0..<30 {
            scrollback.append(Data(String(format: "%09d|", index).utf8))
            scrollback.flush()
        }
        let onDisk = try Data(contentsOf: url)
        #expect(onDisk.count <= 200, "compacted, never more than twice the cap")
        let loaded = scrollback.load()
        #expect(loaded.count == 100)
        #expect(String(decoding: loaded, as: UTF8.self).hasSuffix("000000029|"))
    }

    @Test func clearAndDelete() {
        let (scrollback, url) = file()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        scrollback.append(Data("secret".utf8))
        scrollback.clear()
        scrollback.flush()
        #expect(scrollback.load().isEmpty, "clear drops pending bytes too")
        scrollback.append(Data("again".utf8))
        scrollback.flush()
        scrollback.delete()
        scrollback.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

/// P: the cost of persisting ten busy terminals (plan P2-7).
final class ScrollbackFilePerformanceTests: XCTestCase {
    func testTenBusyTerminalsFlushCost() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "alethe-scrollback-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let chunk = Data(repeating: 0x41, count: 16 * 1024)
        measure(metrics: [XCTClockMetric(), XCTStorageMetric()]) {
            let files = (0..<10).map { ScrollbackFile(url: directory.appending(path: "\($0).bin")) }
            for _ in 0..<64 { for file in files { file.append(chunk) } }  // 10 MiB in all
            for file in files { file.flush() }
        }
    }
}
