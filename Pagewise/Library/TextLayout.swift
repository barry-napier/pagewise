import CoreGraphics
import Foundation

/// One line of text the reader found, with its box in image points
/// (top-left origin).
struct TextLine: Sendable, Equatable {
    var text: String
    var box: CGRect
}

/// Turns loose lines from the text reader back into text that looks like
/// what was on screen: reading order, blank lines, and indentation.
enum TextLayout {
    /// - Parameter keepIndent: rebuild leading spaces from how far right each
    ///   line starts. Right for code and logs, wrong for normal writing.
    static func arrange(_ lines: [TextLine], keepIndent: Bool) -> String {
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }

        let charWidth = median(lines.compactMap { line -> CGFloat? in
            let count = line.text.count
            return count >= 3 ? line.box.width / CGFloat(count) : nil
        }) ?? median(lines.map { $0.box.height * 0.5 }) ?? 8
        let lineHeight = median(lines.map(\.box.height)) ?? 12

        let rows = groupIntoRows(lines)
        let left = rows.map { $0.first!.box.minX }.min() ?? 0

        var output: [String] = []
        var previousBottom: CGFloat?
        for row in rows {
            let top = row.map(\.box.minY).min()!
            let bottom = row.map(\.box.maxY).max()!
            if let previousBottom, top - previousBottom > lineHeight * 0.75 {
                output.append("")
            }
            previousBottom = bottom

            var text = ""
            if keepIndent {
                let indent = Int(((row[0].box.minX - left) / charWidth).rounded())
                text = String(repeating: " ", count: max(0, indent))
            }
            for (index, piece) in row.enumerated() {
                if index > 0 {
                    let gap = (piece.box.minX - row[index - 1].box.maxX) / charWidth
                    text += String(repeating: " ", count: max(1, Int(gap.rounded())))
                }
                text += piece.text.trimmingCharacters(in: .whitespaces)
            }
            output.append(text)
        }
        return output.joined(separator: "\n")
    }

    /// Lines whose middles sit at the same height form one row, left to right.
    static func groupIntoRows(_ lines: [TextLine]) -> [[TextLine]] {
        var rows: [[TextLine]] = []
        for line in lines.sorted(by: { $0.box.midY < $1.box.midY }) {
            if let last = rows.last {
                let top = last.map(\.box.minY).min()!
                let bottom = last.map(\.box.maxY).max()!
                let overlap = min(bottom, line.box.maxY) - max(top, line.box.minY)
                let smaller = min(bottom - top, line.box.height)
                if smaller > 0, overlap / smaller > 0.5 {
                    rows[rows.count - 1].append(line)
                    continue
                }
            }
            rows.append([line])
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }

    // MARK: - Joining broken lines

    /// Joins lines that were only broken because the text wrapped, so a
    /// paragraph becomes one line again. Blank lines, list items and short
    /// lines (headings, last lines) keep their breaks. Words split with a
    /// hyphen at a line end are put back together.
    static func joinBrokenLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let longest = lines.map { $0.trimmingCharacters(in: .whitespaces).count }.max() ?? 0
        var output: [String] = []
        var current: String?

        func flush() {
            if let current { output.append(current) }
            current = nil
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
                output.append("")
                continue
            }
            guard let previous = current else {
                current = line
                continue
            }
            if isListItem(line) || endsParagraph(previous, longest: longest) {
                flush()
                current = line
            } else if previous.hasSuffix("-"), previous.dropLast().last?.isLetter == true,
                      line.first?.isLowercase == true {
                current = String(previous.dropLast()) + line
            } else {
                current = previous + " " + line
            }
        }
        flush()
        return output.joined(separator: "\n")
    }

    static func isListItem(_ line: String) -> Bool {
        line.wholeMatch(of: /^([•◦▪●‣\-*–—]|\d{1,3}[.)]|[a-zA-Z][.)])\s+.*/) != nil
    }

    /// A short line that ends a sentence or has no ending at all, like a
    /// heading, is the end of its paragraph.
    private static func endsParagraph(_ line: String, longest: Int) -> Bool {
        guard longest >= 20 else { return true }  // a short list of words, not prose
        let isShort = line.count < Int(Double(longest) * 0.6)
        guard isShort else { return false }
        return !(line.hasSuffix(",") || line.hasSuffix("-"))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
