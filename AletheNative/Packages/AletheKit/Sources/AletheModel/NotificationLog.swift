import Foundation

/// One in-app notification (upstream `InAppToast`).
public struct AppNotification: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var body: String
    /// The agent tab it is about; clicking it jumps there.
    public var tab: TabID?
    public var agent: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), title: String, body: String, tab: TabID? = nil, agent: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.tab = tab
        self.agent = agent
        self.createdAt = createdAt
    }
}

/// Recent notifications, newest first (upstream `uiStore.notifications`): 12 kept, and the same
/// title and body within 5 s is dropped as a duplicate.
public struct NotificationLog: Sendable {
    public static let capacity = 12
    public static let duplicateWindow: TimeInterval = 5

    public private(set) var entries: [AppNotification] = []
    /// Entries not seen yet (the list was not opened since they came).
    public private(set) var unseen = 0

    public init() {}

    /// Adds an entry; false when it duplicates the last one.
    @discardableResult
    public mutating func post(_ notification: AppNotification) -> Bool {
        if let last = entries.first, last.title == notification.title, last.body == notification.body,
           notification.createdAt.timeIntervalSince(last.createdAt) < Self.duplicateWindow {
            return false
        }
        entries = Array(([notification] + entries).prefix(Self.capacity))
        unseen = min(unseen + 1, Self.capacity)
        return true
    }

    public mutating func markSeen() { unseen = 0 }

    public mutating func clear() {
        entries = []
        unseen = 0
    }
}
