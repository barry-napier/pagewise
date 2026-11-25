import Foundation

/// Checks that a quote the model gave really is in the PDF. The small model
/// can invent text, so an answer only counts when its quotes pass.
///
/// Small differences are allowed: case, spacing, curly quotes, dashes,
/// ligatures, words split by a hyphen, and a word or two the model dropped
/// or misread. A quote that is mostly made up does not pass.
enum QuoteCheck {
    /// Returns the index of the source that holds the quote, or nil.
    /// The `hint` source, the one the model named, is tried first.
    static func find(_ quote: String, in sources: [String], hint: Int? = nil) -> Int? {
        let words = normalizedWords(quote)
        guard words.count >= 3 else {
            // A very short quote proves little. Accept it only as an exact match.
            guard words.count >= 2 else { return nil }
            let phrase = " " + words.joined(separator: " ") + " "
            return order(sources.count, hint: hint).first { index in
                (" " + normalizedWords(sources[index]).joined(separator: " ") + " ").contains(phrase)
            }
        }
        var best: (index: Int, score: Double)?
        for index in order(sources.count, hint: hint) {
            let score = match(words, normalizedWords(sources[index]))
            if score >= 0.8, score > (best?.score ?? 0) {
                best = (index, score)
                if score == 1 { break }
            }
        }
        return best?.index
    }

    /// How much of the quote is in the source, from 0 to 1, measured with
    /// runs of three words, so word order matters.
    static func match(_ quote: [String], _ source: [String]) -> Double {
        let joinedSource = " " + source.joined(separator: " ") + " "
        if joinedSource.contains(" " + quote.joined(separator: " ") + " ") { return 1 }
        let size = quote.count >= 6 ? 3 : 2
        let quoteGrams = grams(quote, size)
        guard !quoteGrams.isEmpty else { return 0 }
        let sourceGrams = Set(grams(source, size))
        let hits = quoteGrams.filter(sourceGrams.contains).count
        return Double(hits) / Double(quoteGrams.count)
    }

    static func normalizedWords(_ text: String) -> [String] {
        var value = text.lowercased()
        let swaps: [(String, String)] = [
            ("ﬁ", "fi"), ("ﬂ", "fl"), ("ﬀ", "ff"), ("ﬃ", "ffi"), ("ﬄ", "ffl"),
            ("’", "'"), ("‘", "'"), ("“", "\""), ("”", "\""), ("–", "-"), ("—", "-"), ("\u{00AD}", ""),
        ]
        for (from, to) in swaps { value = value.replacingOccurrences(of: from, with: to) }
        // A word broken at a line end: "agree- ment" becomes "agreement".
        value = value.replacing(/([a-z])-\s+([a-z])/) { "\($0.1)\($0.2)" }
        return value
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func grams(_ words: [String], _ size: Int) -> [String] {
        guard words.count >= size else { return words.isEmpty ? [] : [words.joined(separator: " ")] }
        return (0...(words.count - size)).map { words[$0..<($0 + size)].joined(separator: " ") }
    }

    private static func order(_ count: Int, hint: Int?) -> [Int] {
        var all = Array(0..<count)
        if let hint, all.indices.contains(hint) {
            all.remove(at: hint)
            all.insert(hint, at: 0)
        }
        return all
    }
}
