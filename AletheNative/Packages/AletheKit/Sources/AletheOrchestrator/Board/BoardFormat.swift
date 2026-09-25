import Foundation
import AletheIntegrations

/// The short readings a worker card shows (upstream `OrchestratorPane/index.tsx`: `formatElapsed`,
/// `formatTokens`, `contextShare`).
public enum BoardFormat {
    /// `42s`, or `3m 07s` from a minute on; nil before the worker started.
    public static func elapsed(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite else { return nil }
        let whole = Int(seconds.rounded(.down))
        if whole < 60 { return "\(whole)s" }
        let rest = whole % 60
        return "\(whole / 60)m \(rest < 10 ? "0" : "")\(rest)s"
    }

    /// `950`, `1.2k` below ten thousand, `42k` from there; nil for no tokens.
    public static func tokens(_ total: Double?) -> String? {
        guard let total, total != 0, total.isFinite else { return nil }
        if total < 1000 { return jsNumber(total) }
        if total < 10_000 {
            // `toFixed(1)`: halves round up, unlike printf's round-half-even.
            let tenths = Int(jsRound(total / 100))
            return "\(tenths / 10).\(tenths % 10)k"
        }
        return jsNumber(jsRound(total / 1000)) + "k"
    }

    /// How much of the model's context window the worker has used, 0…100; nil unless both are known.
    public static func contextShare(_ job: JobSnapshot) -> Int? {
        guard let used = totalTokens(job), used != 0,
              let window = job.tokens?["modelContextWindow"]?.doubleValue, window != 0
        else { return nil }
        return min(100, Int(jsRound(used / window * 100)))
    }

    /// `tokens.total.totalTokens`, the running total both worker kinds report.
    public static func totalTokens(_ job: JobSnapshot) -> Double? {
        job.tokens?["total"]?["totalTokens"]?.doubleValue
    }

    /// A worker's conclusion is the last non-blank line it wrote: the opening one is narration.
    public static func latestLine(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty } ?? ""
    }
}

private extension OrderedJSON {
    subscript(key: String) -> OrderedJSON? { objectValue?[key] }
}

/// JavaScript's `Math.round`: halves go up, towards positive infinity.
func jsRound(_ value: Double) -> Double {
    (value + 0.5).rounded(.down)
}

/// A number the way a JavaScript template literal writes it: integers without a decimal point.
func jsNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
}
