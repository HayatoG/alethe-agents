import Darwin
import Foundation
import Synchronization
import Testing
@testable import AletheIntegrations

// Golden cases: upstream `discord_presence.rs` and the payloads the `discord-rich-presence` 1.1.0 crate writes.
@Suite struct DiscordIPCGoldenTests {
    @Test func applicationIDIsNumeric() {
        #expect(UInt64(DiscordIPC.applicationID) != nil)
    }

    @Test func handshakePayloadMatchesTheCrate() {
        let payload = DiscordIPC.handshakePayload(clientID: DiscordIPC.applicationID)
        #expect(String(decoding: payload, as: UTF8.self) == #"{"client_id":"1517303547761528942","v":1}"#)
    }

    @Test func activityPayloadMatchesTheCrate() {
        let activity = DiscordActivity(details: "Working with Alethe", state: "Managing terminals/tabs", startedAt: 1_700_000_000)
        let payload = DiscordIPC.activityPayload(activity, pid: 4242, nonce: "0b3c2c1e-1111-4222-8333-444455556666")
        #expect(String(decoding: payload, as: UTF8.self) == #"{"args":{"activity":{"assets":{"large_image":"alethe","large_text":"Alethe"},"details":"Working with Alethe","state":"Managing terminals/tabs","timestamps":{"start":1700000000}},"pid":4242},"cmd":"SET_ACTIVITY","nonce":"0b3c2c1e-1111-4222-8333-444455556666"}"#)
    }

    @Test func clearPayloadSendsANullActivity() {
        let payload = DiscordIPC.clearPayload(pid: 7, nonce: "n")
        #expect(String(decoding: payload, as: UTF8.self) == #"{"args":{"activity":null,"pid":7},"cmd":"SET_ACTIVITY","nonce":"n"}"#)
    }
}

@Suite struct DiscordIPCFramingTests {
    @Test func headerIsOpcodeThenLengthLittleEndian() {
        let frame = DiscordIPC.frame(opcode: .frame, payload: Data("{}".utf8))
        #expect([UInt8](frame) == [1, 0, 0, 0, 2, 0, 0, 0, 0x7B, 0x7D])
    }

    @Test func headerRoundTrips() {
        let payload = Data(repeating: 0x20, count: 0x0102)
        let frame = DiscordIPC.frame(opcode: .close, payload: payload)
        let header = DiscordIPC.parseHeader(frame.prefix(8))
        #expect(header?.opcode == 2)
        #expect(header?.length == 0x0102)
        #expect(frame.count == 8 + 0x0102)
    }

    @Test func shortHeaderIsRejected() {
        #expect(DiscordIPC.parseHeader(Data([1, 0, 0])) == nil)
    }

    @Test func searchDirectoriesFollowTheCrateOrder() {
        let dirs = DiscordIPC.defaultSearchDirectories(environment: ["TMPDIR": "/t/", "TMP": "/t/", "TEMP": "/u", "HOME": "/h"])
        #expect(dirs == ["/t/", "/u"])
        let paths = DiscordIPC.candidatePaths(in: ["/t/"])
        #expect(paths.first == "/t/discord-ipc-0")
        #expect(paths.last == "/t/discord-ipc-9")
        #expect(paths.count == 10)
    }
}

/// A fake Discord: listens on a Unix socket, answers the handshake with READY and records every frame.
/// Each thread closes its own descriptor, so `stop()` never races a reused descriptor number.
private final class FakeDiscordServer: Sendable {
    private struct State {
        var frames: [DiscordIPC.Frame] = []
        var connections = 0
        var clients: [Int32] = []
        var stopped = false
    }

    let path: String
    private let listener: Int32
    private let state = Mutex(State())

    init?(path: String, rejectHandshake: Bool = false) {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard DiscordIPCSocket.withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            return nil
        }
        self.path = path
        self.listener = fd
        Thread { [self] in acceptLoop(rejectHandshake: rejectHandshake) }.start()
    }

    var frames: [DiscordIPC.Frame] { state.withLock { $0.frames } }
    var connections: Int { state.withLock { $0.connections } }

    private func acceptLoop(rejectHandshake: Bool) {
        defer { Darwin.close(listener) }
        while !state.withLock({ $0.stopped }) {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 20) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var noTimeout = timeval(tv_sec: 0, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, socklen_t(MemoryLayout<timeval>.size))
            let accepted = state.withLock { state -> Bool in
                guard !state.stopped else { return false }
                state.connections += 1
                state.clients.append(client)
                return true
            }
            guard accepted else {
                Darwin.close(client)
                return
            }
            Thread { [self] in serve(client, rejectHandshake: rejectHandshake) }.start()
        }
    }

    private func serve(_ client: Int32, rejectHandshake: Bool) {
        defer {
            state.withLock { state in
                state.clients.removeAll { $0 == client }
                Darwin.close(client)
            }
        }
        while let frame = DiscordIPCSocket.readFrame(client) {
            state.withLock { $0.frames.append(frame) }
            if frame.opcode == DiscordIPC.Opcode.handshake.rawValue {
                let reply = rejectHandshake
                    ? DiscordIPC.frame(opcode: .close, payload: Data(#"{"code":4000,"message":"Invalid Client ID"}"#.utf8))
                    : DiscordIPC.frame(opcode: .frame, payload: Data(#"{"cmd":"DISPATCH","evt":"READY","data":{"v":1}}"#.utf8))
                _ = DiscordIPCSocket.writeAll(client, reply)
            } else if frame.opcode == DiscordIPC.Opcode.frame.rawValue {
                _ = DiscordIPCSocket.writeAll(client, DiscordIPC.frame(opcode: .frame, payload: Data(#"{"cmd":"SET_ACTIVITY"}"#.utf8)))
            } else if frame.opcode == DiscordIPC.Opcode.close.rawValue {
                return
            }
        }
    }

    /// Discord quitting: the socket path and every connection go away.
    func stop() {
        unlink(path)
        // Wakes each blocked reader; the serving thread closes its own descriptor.
        state.withLock { state in
            state.stopped = true
            for client in state.clients { shutdown(client, SHUT_RDWR) }
        }
    }

    func waitForFrames(_ count: Int) async -> [DiscordIPC.Frame] {
        for _ in 0..<200 where frames.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return frames
    }
}

private final class FakeClock: Sendable {
    private let value = Mutex<TimeInterval>(1000)
    var now: TimeInterval { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 += seconds } }
}

/// A short directory: `sun_path` holds 104 bytes, and the test temporary directory can be long.
private func makeSocketDirectory() throws -> String {
    let path = "/tmp/adipc-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func json(_ frame: DiscordIPC.Frame) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: frame.payload) as? [String: Any]
}

private let sample = DiscordActivity(details: "Working with Alethe", state: "Viewing the dashboard", startedAt: 1_700_000_000)

@Suite(.serialized, .timeLimit(.minutes(1))) struct DiscordIPCClientTests {
    @Test func handshakeThenSetActivity() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0"))
        defer { server.stop() }

        let client = DiscordIPCClient(searchDirectories: [dir])
        #expect(await client.setActivity(sample))
        let frames = await server.waitForFrames(2)
        try #require(frames.count == 2)
        #expect(frames[0].opcode == 0)
        #expect(json(frames[0])?["client_id"] as? String == DiscordIPC.applicationID)
        #expect(json(frames[0])?["v"] as? Int == 1)
        #expect(frames[1].opcode == 1)
        let set = try #require(json(frames[1]))
        #expect(set["cmd"] as? String == "SET_ACTIVITY")
        #expect((set["nonce"] as? String)?.isEmpty == false)
        let args = try #require(set["args"] as? [String: Any])
        #expect(args["pid"] as? Int32 == ProcessInfo.processInfo.processIdentifier)
        let activity = try #require(args["activity"] as? [String: Any])
        #expect(activity["details"] as? String == "Working with Alethe")
        #expect(activity["state"] as? String == "Viewing the dashboard")
        #expect((activity["timestamps"] as? [String: Any])?["start"] as? Int64 == 1_700_000_000)
        #expect((activity["assets"] as? [String: Any])?["large_image"] as? String == "alethe")

        // A second update reuses the connection.
        #expect(await client.setActivity(sample))
        _ = await server.waitForFrames(3)
        #expect(server.connections == 1)
        #expect(server.frames.filter { $0.opcode == 0 }.count == 1)
    }

    @Test func laterSocketIndexIsFound() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-3"))
        defer { server.stop() }

        #expect(await DiscordIPCClient(searchDirectories: [dir]).setActivity(sample))
    }

    @Test func clearSendsNullActivityThenCloses() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0"))
        defer { server.stop() }

        let client = DiscordIPCClient(searchDirectories: [dir])
        #expect(await client.setActivity(sample))
        await client.clearActivity()
        #expect(await client.isConnected == false)
        let frames = await server.waitForFrames(4)
        try #require(frames.count == 4)
        let clear = try #require(json(frames[2])?["args"] as? [String: Any])
        #expect(clear["activity"] is NSNull)
        #expect(frames[3].opcode == 2)
        #expect(String(decoding: frames[3].payload, as: UTF8.self) == "{}")
    }

    @Test func clearWithoutAConnectionDoesNothing() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0"))
        defer { server.stop() }

        await DiscordIPCClient(searchDirectories: [dir]).clearActivity()
        try await Task.sleep(for: .milliseconds(50))
        #expect(server.connections == 0)
    }

    @Test func reconnectsOnceWhenDiscordRestarted() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = "\(dir)/discord-ipc-0"
        let first = try #require(FakeDiscordServer(path: path))
        let client = DiscordIPCClient(searchDirectories: [dir])
        #expect(await client.setActivity(sample))
        _ = await first.waitForFrames(2)
        first.stop()

        let second = try #require(FakeDiscordServer(path: path))
        defer { second.stop() }
        #expect(await client.setActivity(sample))
        let frames = await second.waitForFrames(2)
        #expect(frames.map(\.opcode) == [0, 1])
    }

    @Test func noDiscordStaysSilentAndBacksOff() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let clock = FakeClock()
        let client = DiscordIPCClient(
            searchDirectories: [dir, "/nonexistent-alethe-dir"],
            backoff: .init(initial: 5, maximum: 20),
            now: { clock.now }
        )
        #expect(await client.setActivity(sample) == false)
        await client.clearActivity()

        // Discord starts inside the backoff window: no attempt until it elapses.
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0"))
        defer { server.stop() }
        #expect(await client.setActivity(sample) == false)
        #expect(server.connections == 0)
        clock.advance(5)
        #expect(await client.setActivity(sample))
    }

    @Test func staleSocketFileIsSkipped() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // A leftover socket file from a Discord that quit: exists, refuses connections.
        FileManager.default.createFile(atPath: "\(dir)/discord-ipc-0", contents: Data())
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-1"))
        defer { server.stop() }

        #expect(await DiscordIPCClient(searchDirectories: [dir]).setActivity(sample))
    }

    @Test func rejectedHandshakeIsNotAConnection() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0", rejectHandshake: true))
        defer { server.stop() }

        let client = DiscordIPCClient(searchDirectories: [dir])
        #expect(await client.setActivity(sample) == false)
        #expect(await client.isConnected == false)
    }

    @Test func cancelledTaskDoesNotConnect() async throws {
        let dir = try makeSocketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let server = try #require(FakeDiscordServer(path: "\(dir)/discord-ipc-0"))
        defer { server.stop() }

        let client = DiscordIPCClient(searchDirectories: [dir])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.setActivity(sample)
        }
        #expect(await task.value == false)
        #expect(server.connections == 0)
    }
}
