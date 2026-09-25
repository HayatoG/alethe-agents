import Foundation
import Testing
@testable import AletheModel

/// In-app notifications (P3-11; upstream `pushToast` dedupe and cap).
@Suite struct NotificationLogTests {
    @Test func duplicatesWithinFiveSecondsAreDropped() {
        var log = NotificationLog()
        let start = Date()
        let first = log.post(AppNotification(title: "Claude finished", body: "a", createdAt: start))
        let duplicate = log.post(AppNotification(title: "Claude finished", body: "a", createdAt: start + 2))
        let later = log.post(AppNotification(title: "Claude finished", body: "a", createdAt: start + 6))
        let other = log.post(AppNotification(title: "Claude finished", body: "b", createdAt: start + 6))
        #expect(first && !duplicate && later && other)
        #expect(log.entries.count == 3 && log.unseen == 3)
    }

    @Test func keepsTwelveNewestFirstAndCountsUnseen() {
        var log = NotificationLog()
        for index in 0..<20 { log.post(AppNotification(title: "t\(index)", body: "")) }
        #expect(log.entries.count == NotificationLog.capacity)
        #expect(log.entries.first?.title == "t19")
        log.markSeen()
        #expect(log.unseen == 0)
        log.clear()
        #expect(log.entries.isEmpty)
    }
}
