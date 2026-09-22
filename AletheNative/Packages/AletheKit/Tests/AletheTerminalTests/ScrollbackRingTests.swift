import Foundation
import Testing
@testable import AletheTerminal

@Suite struct ScrollbackRingTests {
    @Test func keepsEverythingUnderCapacity() {
        var ring = ScrollbackRing(capacity: 8)
        ring.append(Data("abc".utf8))
        ring.append(Data("de".utf8))
        #expect(ring.contents == Data("abcde".utf8))
    }

    @Test func dropsOldestBytesWhenFull() {
        var ring = ScrollbackRing(capacity: 8)
        ring.append(Data("abcdef".utf8))
        ring.append(Data("ghij".utf8))
        #expect(ring.contents == Data("cdefghij".utf8))
        #expect(ring.totalAppended == 10)
    }

    @Test func oversizedChunkKeepsItsTail() {
        var ring = ScrollbackRing(capacity: 4)
        ring.append(Data("0123456789".utf8))
        #expect(ring.contents == Data("6789".utf8))
    }

    @Test func wrapsRepeatedly() {
        var ring = ScrollbackRing(capacity: 5)
        for chunk in ["ab", "cd", "ef", "gh", "i"] { ring.append(Data(chunk.utf8)) }
        #expect(ring.contents == Data("efghi".utf8))
    }
}
