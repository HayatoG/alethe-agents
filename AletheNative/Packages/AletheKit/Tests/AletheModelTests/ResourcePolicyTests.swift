import Foundation
import Testing
@testable import AletheModel

/// Port of upstream `resources.rs` tests, plus the native idle mode and mounted tabs (P2-24).
@Suite struct ResourcePolicyTests {
    private func runtime(_ id: String, shell: Bool = false, lastOutput: TimeInterval = 1, started: TimeInterval = 1,
                         used: TimeInterval = 1, memory: Double = 100) -> TerminalRuntime {
        TerminalRuntime(tab: TabID(rawValue: id), isShell: shell, isMounted: false, isFocused: false,
                        lastOutput: lastOutput, startedAt: started, lastUsed: used, memoryMB: memory)
    }

    @Test func manualModeNeverHibernates() {
        let policy = ResourcePolicy()
        #expect(policy.mode == .manual, "manual is the shipped default")
        for level in [MemoryPressure.normal, .warning, .critical] { #expect(!ResourceSupervision.mayHibernate(level, policy: policy)) }
    }

    @Test func pressureModeOnlyWhenCritical() {
        let policy = ResourcePolicy(mode: .pressure)
        #expect(!ResourceSupervision.mayHibernate(.normal, policy: policy))
        #expect(!ResourceSupervision.mayHibernate(.warning, policy: policy))
        #expect(ResourceSupervision.mayHibernate(.critical, policy: policy))
        #expect(ResourceSupervision.mayHibernate(.normal, policy: ResourcePolicy(mode: .idle)), "idle mode ignores pressure")
    }

    @Test func mountedOrFocusedTerminalsAreNeverCandidates() {
        var shown = runtime("a")
        shown.isMounted = true
        var focused = runtime("b")
        focused.isFocused = true
        #expect(ResourceSupervision.candidates([shown, focused], policy: ResourcePolicy(), now: 1_000_000).isEmpty)
    }

    @Test func idleHiddenTerminalBecomesACandidate() {
        #expect(ResourceSupervision.candidates([runtime("a")], policy: ResourcePolicy(), now: 1_000_000) == [TabID(rawValue: "a")])
        let busy = runtime("b", lastOutput: 999_990)
        #expect(ResourceSupervision.candidates([busy], policy: ResourcePolicy(), now: 1_000_000).isEmpty, "printed 10 s ago")
    }

    @Test func spawnGraceProtectsNewTerminals() {
        let fresh = runtime("a", started: 999_999)
        #expect(ResourceSupervision.candidates([fresh], policy: ResourcePolicy(), now: 1_000_000).isEmpty)
    }

    @Test func shellsComeBeforeAgentsThenLeastRecentlyUsed() {
        let agent = runtime("agent", used: 1)
        let shell = runtime("shell", shell: true, used: 5)
        let older = runtime("older", used: 0, memory: 10)
        let ids = ResourceSupervision.candidates([agent, shell, older], policy: ResourcePolicy(), now: 2_000_000)
        #expect(ids.map(\.rawValue) == ["shell", "older", "agent"])
    }

    @Test func pressureFollowsAvailableMemoryWithHysteresis() {
        #expect(MemoryPressure.level(availableMB: 8000, totalMB: 16384, previous: .normal) == .normal)
        #expect(MemoryPressure.level(availableMB: 1200, totalMB: 16384, previous: .normal) == .warning)
        #expect(MemoryPressure.level(availableMB: 600, totalMB: 16384, previous: .normal) == .critical)
        let criticalAt = 16384 * 0.05
        #expect(MemoryPressure.level(availableMB: criticalAt * 1.2, totalMB: 16384, previous: .critical) == .critical,
                "held until 25 % past the threshold")
    }

    @Test func policyValuesAreClamped() {
        let policy = ResourcePolicy(mode: .idle, hiddenAgentIdleMinutes: 1, hiddenShellIdleMinutes: 10_000, spawnGraceSeconds: 1).normalized
        #expect(policy.hiddenAgentIdleMinutes == 5 && policy.hiddenShellIdleMinutes == 480 && policy.spawnGraceSeconds == 30)
    }

    @Test func mountedTabsAreTheShownTabsOfOpenContainers() {
        var doc = WorkspaceDocument()
        let open = doc.addProject(name: "open", folder: "/o")
        let closed = doc.addProject(name: "closed", folder: "/c")
        let shown = PaneTab(agent: "shell"), hidden = PaneTab(agent: "shell"), elsewhere = PaneTab(agent: "shell")
        let pane = doc.addPane(to: open, tab: hidden)
        if let pane { doc.addTab(shown, to: pane) }
        doc.addPane(to: closed, tab: elsewhere)
        doc.close(closed)
        #expect(doc.mountedTabIDs == [shown.id], "an inactive sub-tab and a closed project are not mounted")
    }
}
