import Foundation

/// Fuzzy matching for Find/Jump (P2-25). Upstream `FindJumpModal` filters by substring; the native
/// jump ranks instead: every query character must appear in order, and matches score higher when
/// they are consecutive, start a word, start the text or match case.
public enum FuzzyMatch {
    public struct Result: Equatable, Sendable {
        public var score: Int
        /// Offsets (in `Character`s) of the matched characters, for highlighting.
        public var positions: [Int]
    }

    /// Nil when `query` does not match `text`; an empty query matches everything with score 0.
    public static func match(_ query: String, in text: String) -> Result? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Result(score: 0, positions: []) }
        let original = Array(text)
        let haystack = Array(text.lowercased())
        guard haystack.count == original.count else { return substringFallback(needle, haystack) }

        // Greedy forward pass finds a match; a backward pass from its end tightens it to the
        // shortest window, which is what scores consecutive runs well.
        var positions: [Int] = []
        var index = 0
        for character in needle {
            while index < haystack.count, haystack[index] != character { index += 1 }
            guard index < haystack.count else { return nil }
            positions.append(index)
            index += 1
        }
        var end = positions.last!
        var tightened: [Int] = []
        for character in needle.reversed() {
            while end >= 0, haystack[end] != character { end -= 1 }
            tightened.append(end)
            end -= 1
        }
        positions = tightened.reversed()

        var score = 0
        for (offset, position) in positions.enumerated() {
            score += 1
            if offset > 0, positions[offset - 1] == position - 1 { score += 5 }
            if position == 0 {
                score += 8
            } else if isBoundary(original[position - 1], original[position]) {
                score += 6
            }
            if original[position] == Array(query.filter { !$0.isWhitespace })[offset] { score += 1 }
        }
        // Tighter and earlier matches win; shorter texts break ties.
        score -= (positions.last! - positions.first!) - (positions.count - 1)
        score -= positions.first! / 4
        score -= haystack.count / 16
        return Result(score: score, positions: positions)
    }

    private static func isBoundary(_ previous: Character, _ current: Character) -> Bool {
        if previous == " " || previous == "-" || previous == "_" || previous == "/" || previous == "." || previous == "·" {
            return true
        }
        return previous.isLowercase && current.isUppercase
    }

    private static func substringFallback(_ needle: [Character], _ haystack: [Character]) -> Result? {
        String(haystack).contains(String(needle)) ? Result(score: 1, positions: []) : nil
    }

    /// Items ranked by their best field; items that match nothing are dropped. Stable for equal
    /// scores, so an empty query keeps the given order.
    public static func rank<Item>(_ items: [Item], query: String, fields: (Item) -> [String]) -> [(item: Item, score: Int)] {
        items.enumerated()
            .compactMap { offset, item -> (Int, Item, Int)? in
                let best = fields(item).compactMap { match(query, in: $0)?.score }.max()
                return best.map { (offset, item, $0) }
            }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.0 < $1.0 }
            .map { ($0.1, $0.2) }
    }
}
