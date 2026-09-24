import Darwin
import Foundation
import Testing
@testable import AletheTerminal

@Suite struct ForceKillTests {
    private let ctrlC = Data([0x03])
    private let start = ContinuousClock.now

    @Test func secondInterruptWithinTheWindowKills() {
        var detector = DoubleInterrupt()
        #expect(!detector.register(ctrlC, at: start), "the first ⌃C reaches the program")
        #expect(detector.register(ctrlC, at: start + .milliseconds(1400)))
    }

    @Test func slowInterruptsNeverKill() {
        var detector = DoubleInterrupt()
        #expect(!detector.register(ctrlC, at: start))
        #expect(!detector.register(ctrlC, at: start + .milliseconds(1500)))
        #expect(!detector.register(ctrlC, at: start + .milliseconds(3100)))
    }

    @Test func typingInBetweenStartsOver() {
        var detector = DoubleInterrupt()
        #expect(!detector.register(ctrlC, at: start))
        #expect(!detector.register(Data("x".utf8), at: start + .milliseconds(100)))
        #expect(!detector.register(ctrlC, at: start + .milliseconds(200)))
    }

    @Test func aKillResetsTheCount() {
        var detector = DoubleInterrupt()
        _ = detector.register(ctrlC, at: start)
        #expect(detector.register(ctrlC, at: start + .milliseconds(100)))
        #expect(!detector.register(ctrlC, at: start + .milliseconds(200)))
    }

    @Test func recognizesKittyKeyboardInterrupts() {
        #expect(DoubleInterrupt.isInterrupt(Data("\u{1b}[99;5u".utf8)))
        #expect(DoubleInterrupt.isInterrupt(Data("\u{1b}[99;5:1u".utf8)))
        #expect(!DoubleInterrupt.isInterrupt(Data("\u{1b}[99;5:3u".utf8)), "a key release is not a press")
        #expect(!DoubleInterrupt.isInterrupt(Data("c".utf8)))
        #expect(!DoubleInterrupt.isInterrupt(Data([0x03, 0x03])), "pasted bytes are not a keypress")
    }

    @Test func descendantsFollowTheWholeTree() {
        // 10 ─┬─ 11 ── 13
        //     └─ 12        20 is unrelated; 1 is launchd.
        let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 10, 13: 11, 20: 1, 1: 1]
        #expect(ProcessTree.descendants(of: 10, parents: parents) == [10, 11, 12, 13])
        #expect(ProcessTree.descendants(of: 99, parents: parents) == [99])
    }

    @Test func killReachesAChildInItsOwnProcessGroup() throws {
        // A shell whose child leaves the group (like an agent's workers): SIGKILL to the group alone
        // would miss it.
        let process = try PTYProcess(PTYLaunch(
            executable: "/bin/sh", arguments: ["sh", "-c", "perl -e 'setpgrp(0,0); sleep 30' & wait"],
            environment: ["PATH": "/usr/bin:/bin"], workingDirectory: nil, size: PTYSize(columns: 80, rows: 24)))
        process.start()
        var child: pid_t?
        for _ in 0..<50 where child == nil {
            child = ProcessTree.descendants(of: process.pid, parents: ProcessTree.currentParents()).dropFirst().first
            usleep(100_000)
        }
        let pid = try #require(child)
        ProcessTree.kill(process.pid)
        var alive = true
        for _ in 0..<50 where alive {
            alive = Darwin.kill(pid, 0) == 0
            usleep(100_000)
        }
        #expect(!alive)
    }
}
