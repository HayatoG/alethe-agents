import Darwin
import Foundation
import Testing
@testable import AletheTerminal

/// Memory sampling (P2-24). The P case: a process tree's memory is measured, and nothing is left
/// once the tree is ended, which is what a hibernated terminal gives back.
@Suite struct SystemResourcesTests {
    @Test func systemMemoryIsSane() {
        let memory = SystemResources.memory()
        #expect(memory.totalMB > 1024)
        #expect(memory.availableMB > 0 && memory.availableMB <= memory.totalMB)
    }

    @Test func footprintOfThisProcessAndOfAMissingOne() {
        #expect(SystemResources.footprintMB(of: getpid()) > 1)
        #expect(SystemResources.footprintMB(of: 999_999) == 0)
    }

    @Test func endingATreeGivesItsMemoryBack() async throws {
        let parent = Process()
        parent.executableURL = URL(filePath: "/bin/sh")
        parent.arguments = ["-c", "/bin/sleep 30 & /bin/sleep 30; wait"]
        try parent.run()
        try await Task.sleep(for: .milliseconds(300))
        let root = parent.processIdentifier
        let parents = ProcessTree.currentParents()
        #expect(ProcessTree.descendants(of: root, parents: parents).count >= 3, "the shell and its two children")
        let measured = SystemResources.treeFootprintMB(of: root, parents: parents)
        #expect(measured >= SystemResources.footprintMB(of: root))
        ProcessTree.kill(root)
        parent.waitUntilExit()
        try await Task.sleep(for: .milliseconds(200))
        #expect(SystemResources.treeFootprintMB(of: root, parents: ProcessTree.currentParents()) == 0)
    }
}
