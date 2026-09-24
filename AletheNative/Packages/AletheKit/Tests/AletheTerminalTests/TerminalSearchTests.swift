import Testing
@testable import AletheTerminal

@MainActor
@Suite struct TerminalSearchTests {
    @Test func statusFollowsGhosttyProgress() {
        let search = TerminalSearch()
        #expect(search.status == .none)
        search.needle = "alpha"
        #expect(search.status == .none, "still counting")
        search.total = 0
        #expect(search.status == .noResults)
        search.total = 4
        #expect(search.status == .count(4))
        search.selected = 0
        #expect(search.status == .match(position: 1, total: 4))
        search.selected = 9
        #expect(search.status == .count(4), "a stale index is not shown")
        search.needle = ""
        #expect(search.status == .none)
    }

    @Test func bindingNeedleIsOneCleanLine() {
        #expect(TerminalSearch.bindingNeedle("alpha") == "alpha")
        #expect(TerminalSearch.bindingNeedle("first\nsecond") == "first")
        #expect(TerminalSearch.bindingNeedle("a\u{1b}b\tc") == "abc")
        #expect(TerminalSearch.bindingNeedle("ação 🚀") == "ação 🚀")
    }
}
