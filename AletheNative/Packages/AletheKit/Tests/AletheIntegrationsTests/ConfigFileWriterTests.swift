import Foundation
import Testing
@testable import AletheIntegrations

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "AletheIntegrationsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A clock that advances one second per call, so backups get distinct, ordered names.
private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    func next() -> Date {
        lock.withLock {
            current = current.addingTimeInterval(1)
            return current
        }
    }
}

private func makeWriter(_ root: URL) -> ConfigFileWriter {
    let clock = SteppingClock()
    return ConfigFileWriter(profileDirectory: root.appending(path: "profile"), now: { clock.next() })
}

private let slot = ConfigBackupSlot(agent: "claude", kind: "user")

@Suite struct ConfigFileWriterTests {
    @Test func readsMissingFileAsAbsent() throws {
        let root = temporaryDirectory()
        let snapshot = try makeWriter(root).read(root.appending(path: "none.json"))
        #expect(!snapshot.exists)
        #expect(snapshot.text.isEmpty)
        #expect(snapshot.modificationDate == nil)
    }

    @Test func createsAMissingFileWithoutABackup() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "nested/.mcp.json")
        let report = try writer.write("{}\n", over: writer.read(url), backupSlot: slot)
        #expect(report.backup == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == "{}\n")
        #expect(writer.backups(in: slot).isEmpty)
    }

    @Test func refusesWhenTheFileChangedSinceRead() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        try Data("{\"a\": 1}".utf8).write(to: url)
        let snapshot = try writer.read(url)
        try Data("{\"a\": 2}".utf8).write(to: url)
        #expect(throws: ConfigFileError.changedSinceRead(url)) {
            try writer.write("{}", over: snapshot, backupSlot: slot)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{\"a\": 2}")
        #expect(writer.backups(in: slot).isEmpty)
    }

    @Test func refusesWhenAMissingFileAppearedOrAnExistingOneWasRemoved() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        let missing = try writer.read(url)
        try Data("outside".utf8).write(to: url)
        #expect(throws: ConfigFileError.changedSinceRead(url)) { try writer.write("{}", over: missing, backupSlot: slot) }

        let present = try writer.read(url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: ConfigFileError.changedSinceRead(url)) { try writer.write("{}", over: present, backupSlot: slot) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func refusesWhenOnlyTheModificationDateChanged() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        try Data("same".utf8).write(to: url)
        let snapshot = try writer.read(url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        #expect(throws: ConfigFileError.changedSinceRead(url)) { try writer.write("new", over: snapshot, backupSlot: slot) }
    }

    @Test func backsUpThePreviousContentsBeforeWriting() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.toml")
        try Data("old = 1\n".utf8).write(to: url)
        let report = try writer.write("new = 2\n", over: writer.read(url), backupSlot: ConfigBackupSlot(agent: "codex", kind: "project"))
        let backup = try #require(report.backup)
        #expect(try String(contentsOf: backup.url, encoding: .utf8) == "old = 1\n")
        #expect(backup.url.pathExtension == "toml")
        #expect(backup.url.deletingLastPathComponent().lastPathComponent == "codex-project")
        #expect(backup.url.path.contains("/profile/config-backups/codex-project/"))
        #expect(try String(contentsOf: url, encoding: .utf8) == "new = 2\n")
        let permissions = try FileManager.default.attributesOfItem(atPath: backup.url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func rotatesBackupsToTheNewestTen() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        try Data("0".utf8).write(to: url)
        for index in 1...(ConfigFileWriter.maxBackups + 4) {
            try writer.write("\(index)", over: writer.read(url), backupSlot: slot)
        }
        let backups = writer.backups(in: slot)
        #expect(backups.count == ConfigFileWriter.maxBackups)
        // Newest first: the last write backed up "13", the oldest kept is "4".
        #expect(try String(contentsOf: backups[0].url, encoding: .utf8) == "13")
        #expect(try String(contentsOf: backups[9].url, encoding: .utf8) == "4")
        #expect(backups.map(\.createdAt) == backups.map(\.createdAt).sorted(by: >))
    }

    @Test func pruningLeavesOtherSlotsAlone() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        let other = ConfigBackupSlot(agent: "cursor", kind: "user")
        try Data("x".utf8).write(to: url)
        try writer.write("y", over: writer.read(url), backupSlot: other)
        for index in 0..<(ConfigFileWriter.maxBackups + 2) {
            try writer.write("\(index)", over: writer.read(url), backupSlot: slot)
        }
        #expect(writer.backups(in: other).count == 1)
        #expect(writer.backups(in: slot).count == ConfigFileWriter.maxBackups)
    }

    @Test func restoresABackupAndBacksUpTheCurrentContents() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        try Data("first".utf8).write(to: url)
        let report = try writer.write("second", over: writer.read(url), backupSlot: slot)
        let restored = try writer.restore(try #require(report.backup), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "first")
        #expect(try String(contentsOf: try #require(restored.backup).url, encoding: .utf8) == "second")
        #expect(writer.backups(in: slot).count == 2)
    }

    @Test func keepsTheFilePermissions() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let url = root.appending(path: "config.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try writer.write("{\"a\": 1}", over: writer.read(url), backupSlot: nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("alethe-tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func writesThroughASymlink() throws {
        let root = temporaryDirectory()
        let writer = makeWriter(root)
        let real = root.appending(path: "dotfiles/claude.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: real)
        let link = root.appending(path: ".claude.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try writer.write("{\"b\": 2}", over: writer.read(link), backupSlot: nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "{\"b\": 2}")
    }

    @Test func slotNamesStayOnePathComponent() {
        #expect(ConfigBackupSlot(agent: "../Claude", kind: "user/x").name == "___claude-user_x")
        #expect(ConfigBackupSlot(agent: "", kind: "local").name == "_-local")
    }
}

@Suite struct SecretTests {
    @Test func hidesShortValuesEntirely() {
        #expect(Secret.mask("") == "")
        #expect(Secret.mask("abc") == "•••")
        #expect(Secret.mask("short-11ch") == "••••••••")
    }

    @Test func keepsOnlyTheTailOfLongValues() {
        let masked = Secret.mask("sk-proj-abcdefghijklmnop")
        #expect(masked == "••••••••mnop")
        #expect(!masked.contains("abcdefghijkl"))
    }
}
