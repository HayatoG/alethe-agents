/// Secrets shown in the UI (MCP env values, tokens).
public enum Secret {
    /// Upstream `mask_secret`: values under 12 characters are fully hidden (at most 8 dots); longer
    /// ones show only their last four characters, which cannot meaningfully narrow them down.
    public static func mask(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        guard !scalars.isEmpty else { return "" }
        guard scalars.count >= 12 else { return String(repeating: "•", count: min(scalars.count, 8)) }
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars.suffix(4))
        return String(repeating: "•", count: 8) + String(tail)
    }
}
