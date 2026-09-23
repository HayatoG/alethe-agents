import Foundation
import Synchronization
import Testing
@testable import AletheTerminal

/// A fake terminal on a virtual clock: `sleep` advances time instantly.
private final class FakeTerminal: Sendable {
    let clock = Mutex<Duration>(.zero)
    let lastOutput = Mutex<Duration>(.zero)
    let written = Mutex<[String]>([])
    let screen = Mutex<String>("")
    let running = Mutex(true)
    /// Called after each write, to let a test react (e.g. echo typed text on screen).
    let onWrite: @Sendable (FakeTerminal, String) -> Void

    init(onWrite: @escaping @Sendable (FakeTerminal, String) -> Void = { _, _ in }) {
        self.onWrite = onWrite
    }

    var io: PromptDelivery.IO {
        PromptDelivery.IO(
            now: { self.clock.withLock { $0 } },
            sleep: { duration in self.clock.withLock { $0 += duration } },
            quietFor: { self.clock.withLock { $0 } - self.lastOutput.withLock { $0 } },
            isRunning: { self.running.withLock { $0 } },
            readScreen: { self.screen.withLock { $0 } },
            write: { text in
                self.written.withLock { $0.append(text) }
                self.onWrite(self, text)
            })
    }

    func output(at time: Duration) { lastOutput.withLock { $0 = time } }
}

@Suite struct PromptDeliveryTests {
    @Test func pastesOnceTheAgentGoesQuiet() async {
        let terminal = FakeTerminal()
        terminal.output(at: .seconds(2))  // still drawing at 2 s → quiet for 700 ms at 2.7 s
        let sent = await PromptDelivery.deliver("fix the tests\nplease", style: .paste, io: terminal.io)
        #expect(sent)
        let written = terminal.written.withLock { $0 }
        #expect(written.prefix(2) == ["\u{1b}[200~fix the tests\nplease\u{1b}[201~", "\r"])
        #expect(terminal.clock.withLock { $0 } >= .milliseconds(2700))
    }

    @Test func neverSendsBeforeTheMinimumWait() async {
        let terminal = FakeTerminal()
        _ = await PromptDelivery.deliver("hi", style: .paste, io: terminal.io)
        #expect(terminal.clock.withLock { $0 } >= .milliseconds(1500))
    }

    @Test func givesUpWhenTheAgentExits() async {
        let terminal = FakeTerminal()
        terminal.running.withLock { $0 = false }
        #expect(await PromptDelivery.deliver("hi", style: .paste, io: terminal.io) == false)
        #expect(terminal.written.withLock { $0 }.isEmpty)
    }

    @Test func blankPromptsAreNotSent() async {
        #expect(await PromptDelivery.deliver("  \n", style: .paste, io: FakeTerminal().io) == false)
    }

    @Test func openCodeTypesInChunksAndConfirmsOnScreenBeforeEnter() async {
        let terminal = FakeTerminal { terminal, text in
            if text == "\r" {
                terminal.screen.withLock { $0 = "thinking…" }
            } else {
                terminal.screen.withLock { $0 += text }
            }
        }
        terminal.screen.withLock { $0 = "┃ Ask anything" }
        let sent = await PromptDelivery.deliver("refactor the parser", style: .typeAndConfirm, io: terminal.io)
        #expect(sent)
        let written = terminal.written.withLock { $0 }
        #expect(written.dropLast().allSatisfy { $0.count <= 6 })
        #expect(written.dropLast().joined() == "refactor the parser")
        #expect(written.last == "\r")
        #expect(terminal.clock.withLock { $0 } >= .seconds(4))
    }

    @Test func openCodeResendsEnterOnlyWhileNothingHappens() async {
        let enters = Mutex(0)
        let terminal = FakeTerminal { terminal, text in
            if text == "\r" {
                let count = enters.withLock { $0 += 1; return $0 }
                if count == 2 { terminal.screen.withLock { $0 = "working" } }
            } else {
                terminal.screen.withLock { $0 += text }
            }
        }
        #expect(await PromptDelivery.deliver("hello", style: .typeAndConfirm, io: terminal.io))
        #expect(enters.withLock { $0 } == 2)
    }

    @Test func matchingIgnoresBordersAndPunctuation() {
        #expect(PromptDelivery.normalizedForMatch("┃ Fix the\n┃ parser!") == "fixtheparser")
    }
}
