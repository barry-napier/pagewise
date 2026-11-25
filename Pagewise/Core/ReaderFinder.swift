import Foundation
import PDFKit

/// Finds a quote on a PDF page, for highlighting.
enum ReaderFinder {
    /// The quote's words are matched in the page's text with any spacing
    /// between them, so line breaks and hyphens in the PDF don't matter.
    /// If the whole quote isn't there, it finds the start and the end
    /// separately and selects everything between them.
    static func find(_ quote: String, on page: PDFPage, in document: PDFDocument) -> PDFSelection? {
        guard let text = page.string, !text.isEmpty else { return nil }
        let words = quote
            .trimmingCharacters(in: CharacterSet(charactersIn: "“”\"' ").union(.whitespacesAndNewlines))
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !words.isEmpty else { return nil }

        if let whole = range(of: words[...], in: text) {
            return page.selection(for: whole)
        }
        var start: NSRange?
        for count in [8, 5, 3] where words.count > count {
            if let found = range(of: words.prefix(count), in: text) {
                start = found
                break
            }
        }
        guard let start else { return nil }
        for count in [6, 4, 3] where words.count > count {
            if let end = range(of: words.suffix(count), in: text, from: start.location), end.location >= start.location {
                return page.selection(for: NSRange(location: start.location, length: NSMaxRange(end) - start.location))
            }
        }
        return page.selection(for: start)
    }

    static func range(of words: ArraySlice<String>, in text: String, from location: Int = 0) -> NSRange? {
        let pattern = words.map { word in
            NSRegularExpression.escapedPattern(for: word)
                .replacingOccurrences(of: "'", with: "['’]")
                .replacingOccurrences(of: "’", with: "['’]")
        }.joined(separator: "[\\s\\-\u{00AD}‐]+")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        let searchRange = NSRange(location: location, length: ns.length - location)
        return regex.firstMatch(in: text, range: searchRange)?.range
    }
}
