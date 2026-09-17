import Foundation

/// A typed query, normalised once so every detector reads the same cheap views instead of
/// re-lowercasing and re-splitting. Foundation-only; nothing here reaches the environment.
struct QueryText: Sendable {
    let raw: String
    let trimmed: String
    let lowercased: String
    let words: [Substring]

    init(_ raw: String) {
        self.raw = raw
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.trimmed = trimmed
        let lowercased = trimmed.lowercased()
        self.lowercased = lowercased
        self.words = lowercased.split(whereSeparator: \.isWhitespace)
    }

    var isEmpty: Bool { trimmed.isEmpty }

    /// The first whitespace-delimited word, lowercased — the command word a shell phrase leads with.
    var firstWord: Substring { words.first ?? "" }

    /// True when any needle appears anywhere in the lowercased query.
    func containsAny(of needles: [String]) -> Bool {
        needles.contains { lowercased.contains($0) }
    }
}
