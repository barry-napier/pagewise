import Foundation
import NaturalLanguage

/// The text of one PDF page. Pages count from 0.
struct PageText: Sendable, Equatable {
    var page: Int
    var text: String
}

/// A small piece of a page: what gets searched and sent to the model.
struct Piece: Sendable, Equatable {
    var page: Int
    var text: String
}

/// Cuts pages into pieces of about `targetWords` words, at sentence ends.
/// Pieces never cross pages, so every piece has one exact page number.
/// Neighbouring pieces share a little text, so a fact on the border of two
/// pieces is still whole in one of them.
enum Splitter {
    static func split(_ pages: [PageText], targetWords: Int = 120, overlapWords: Int = 25) -> [Piece] {
        var pieces: [Piece] = []
        for page in pages {
            let text = clean(page.text)
            guard !text.isEmpty else { continue }
            var current: [String] = []
            var count = 0
            for sentence in sentences(in: text, maxWords: targetWords) {
                let words = wordCount(sentence)
                if count > 0, count + words > targetWords {
                    pieces.append(Piece(page: page.page, text: current.joined(separator: " ")))
                    // Carry the last sentences into the next piece.
                    var carry: [String] = []
                    var carried = 0
                    for previous in current.reversed() {
                        let n = wordCount(previous)
                        if carried + n > overlapWords { break }
                        carry.insert(previous, at: 0)
                        carried += n
                    }
                    current = carry
                    count = carried
                }
                current.append(sentence)
                count += words
            }
            if !current.isEmpty {
                let last = current.joined(separator: " ")
                // Skip a tail that only repeats the end of the last piece.
                if let previous = pieces.last, previous.page == page.page, previous.text.hasSuffix(last) { continue }
                pieces.append(Piece(page: page.page, text: last))
            }
        }
        return pieces
    }

    /// Joins lines that only wrapped, mends words split with a hyphen, and
    /// keeps one space between words.
    static func clean(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00AD}", with: "")  // soft hyphen
        let joined = TextLayout.joinBrokenLines(normalized)
        return joined
            .replacing(/[ \t]+/, with: " ")
            .replacing(/\n{3,}/, with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sentences, with very long ones cut into word runs.
    static func sentences(in text: String, maxWords: Int) -> [String] {
        // Lines stay apart, so a heading never joins the sentence below it.
        text.components(separatedBy: "\n").flatMap { sentencesInLine($0, maxWords: maxWords) }
    }

    private static func sentencesInLine(_ text: String, maxWords: Int) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            guard !sentence.isEmpty else { return true }
            let words = sentence.split(separator: " ")
            if words.count > maxWords {
                stride(from: 0, to: words.count, by: maxWords).forEach { start in
                    result.append(words[start..<min(start + maxWords, words.count)].joined(separator: " "))
                }
            } else {
                result.append(sentence)
            }
            return true
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}
