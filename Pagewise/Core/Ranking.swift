import Accelerate
import Foundation

/// Search maths: meaning scores, joining two ranked lists, and filling the
/// model's limited space.
enum Ranking {
    /// Dot product of two normalised vectors, which is their cosine.
    static func similarity(_ a: [Float], _ b: ArraySlice<Float>) -> Float {
        precondition(a.count == b.count)
        return a.withUnsafeBufferPointer { left in
            b.withUnsafeBufferPointer { right in
                vDSP.dot(left, right)
            }
        }
    }

    static func normalize(_ vector: [Float]) -> [Float] {
        let length = sqrt(vDSP.sumOfSquares(vector))
        guard length > 0 else { return vector }
        return vDSP.divide(vector, length)
    }

    /// Joins ranked lists with reciprocal rank fusion: an item near the top
    /// of either list, or fairly high in both, ends up near the top.
    static func fuse<ID: Hashable>(_ lists: [[ID]], k: Double = 60) -> [ID] {
        var scores: [ID: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() {
                scores[id, default: 0] += 1 / (k + Double(rank + 1))
            }
        }
        return scores.sorted { $0.value == $1.value ? "\($0.key)" < "\($1.key)" : $0.value > $1.value }.map(\.key)
    }

    /// Takes items in order while their cost fits in the budget. Skips an
    /// item that is too big and tries the next.
    static func pack<Item>(_ items: [Item], budget: Int, cost: (Item) -> Int) -> [Item] {
        var used = 0
        var chosen: [Item] = []
        for item in items {
            let size = cost(item)
            if used + size <= budget {
                chosen.append(item)
                used += size
            }
        }
        return chosen
    }

    /// Words worth searching for: drops short and very common words.
    static func keywords(_ question: String) -> [String] {
        let stop: Set<String> = [
            "the", "and", "for", "are", "was", "what", "when", "where", "which", "who", "whom", "how", "why",
            "does", "did", "this", "that", "these", "those", "with", "from", "about", "into", "there", "their",
            "they", "them", "have", "has", "had", "can", "could", "should", "would", "will", "you", "your",
            "any", "all", "say", "says", "tell", "much", "many", "pdf", "document", "page", "pages", "not",
            "but", "our", "out", "its", "his", "her", "she", "him", "per", "than", "then", "also", "some",
        ]
        var seen = Set<String>()
        return question.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { ($0.count >= 3 || $0.allSatisfy(\.isNumber)) && !stop.contains($0) && seen.insert($0).inserted }
    }

    /// A word-search query for SQLite's full-text search: any of the words.
    static func ftsQuery(_ question: String) -> String? {
        let words = keywords(question)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}
