import Foundation

/// Where the user put each contributed sidebar tab (upstream `viewPlacement.ts`, `viewPlacements`):
/// the ordered tab ids per side. A tab without an entry stays on its contribution's side, after the
/// placed ones, in contribution order. Ids of tabs not contributed right now (a disabled plugin) are
/// kept, so the placement survives until the plugin comes back.
public struct ViewPlacements: Hashable, Sendable, Codable {
    public var left: [String]
    public var right: [String]

    public init(left: [String] = [], right: [String] = []) {
        self.left = left
        self.right = right
    }

    public static let empty = ViewPlacements()

    /// The tabs of each side, in display order.
    public func arranged(_ tabs: [SidebarTabContribution]) -> (left: [SidebarTabContribution], right: [SidebarTabContribution]) {
        var byID: [String: SidebarTabContribution] = [:]
        for tab in tabs where byID[tab.id] == nil { byID[tab.id] = tab }
        var used = Set<String>()
        func placed(_ ids: [String]) -> [SidebarTabContribution] {
            ids.compactMap { id in
                guard let tab = byID[id], used.insert(id).inserted else { return nil }
                return tab
            }
        }
        var left = placed(self.left)
        var right = placed(self.right)
        for tab in tabs where used.insert(tab.id).inserted {
            if tab.side == .left { left.append(tab) } else { right.append(tab) }
        }
        return (left, right)
    }

    /// The side a tab shows on.
    public func side(of id: String, in tabs: [SidebarTabContribution]) -> SidebarSide? {
        let arranged = arranged(tabs)
        if arranged.left.contains(where: { $0.id == id }) { return .left }
        if arranged.right.contains(where: { $0.id == id }) { return .right }
        return nil
    }

    /// Moves a tab to `side` at `index` (clamped) of that side's current order. Unknown ids are ignored.
    public mutating func move(_ id: String, to side: SidebarSide, at index: Int, in tabs: [SidebarTabContribution]) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let arranged = arranged(tabs)
        var left = arranged.left.map(\.id).filter { $0 != id }
        var right = arranged.right.map(\.id).filter { $0 != id }
        if side == .left {
            left.insert(id, at: min(max(index, 0), left.count))
        } else {
            right.insert(id, at: min(max(index, 0), right.count))
        }
        let current = Set(tabs.map(\.id))
        self.left = left + self.left.filter { !current.contains($0) }
        self.right = right + self.right.filter { !current.contains($0) }
    }

    /// Returns every tab to its contributed side and order.
    public mutating func reset() {
        self = .empty
    }
}
