import Testing
@testable import AletheFoundation

struct DictationMachineTests {
    @Test func shortPressToggles() {
        var machine = DictationMachine()
        #expect(machine.keyDown(at: 0) == .start)
        #expect(machine.keyUp(at: 0.1) == .none)
        machine.started()
        #expect(machine.phase == .listening)
        #expect(machine.keyDown(at: 3) == .stop)
        #expect(machine.phase == .finishing)
        #expect(machine.keyUp(at: 3.1) == .none)
        machine.finished()
        #expect(machine.phase == .idle)
    }

    @Test func holdStopsOnRelease() {
        var machine = DictationMachine()
        #expect(machine.keyDown(at: 0) == .start)
        machine.started()
        #expect(machine.keyUp(at: 2) == .stop)
        #expect(machine.phase == .finishing)
    }

    @Test func escapeCancelsAndFailureRestarts() {
        var machine = DictationMachine()
        #expect(machine.toggle() == .start)
        #expect(machine.escape() == .cancel)
        #expect(machine.phase == .idle)
        #expect(machine.toggle() == .start)
        machine.failed(.microphoneDenied)
        #expect(machine.phase == .failed(.microphoneDenied))
        #expect(!machine.isActive)
        #expect(machine.keyUp(at: 5) == .none)
        #expect(machine.keyDown(at: 6) == .start)
        #expect(machine.escape() == .cancel)
        #expect(machine.escape() == .none)
    }
}
