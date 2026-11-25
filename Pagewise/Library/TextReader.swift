import CoreGraphics
import Foundation
import Vision

/// What Apple's text reader found in an image.
struct ReadResult: Sendable {
    var lines: [TextLine] = []
    /// Each table as rows of cells.
    var tables: [[[String]]] = []
    /// Share of the text, by characters, that sits inside tables.
    var tableShare: Double = 0
    /// What QR codes and barcodes say.
    var barcodes: [String] = []
}

/// Reads text, tables and QR codes from an image with Apple's Vision
/// framework. Everything runs on this Mac.
enum TextReader {
    /// - Parameter quick: skips tables and QR codes. Used when watching a box,
    ///   where only the words matter and speed does.
    static func read(_ image: CGImage, quick: Bool = false) async throws -> ReadResult {
        let size = CGSize(width: image.width, height: image.height)
        if quick {
            return ReadResult(lines: try await readLines(image, size: size))
        }

        var result = ReadResult()
        let documents = (try? await RecognizeDocumentsRequest().perform(on: image)) ?? []
        for observation in documents {
            let container = observation.document
            result.lines += container.text.lines.compactMap { line(from: $0, size: size) }
            for table in container.tables {
                let rows = cells(of: table)
                if rows.count >= 2, rows.contains(where: { $0.count >= 2 }) {
                    result.tables.append(rows)
                }
            }
            result.barcodes += container.barcodes.compactMap(\.payloadString)
        }
        // The document reader can miss loose text, like a single word on a
        // button. Fall back to the plain line reader when it finds nothing.
        if result.lines.isEmpty {
            result.lines = try await readLines(image, size: size)
        }
        if result.barcodes.isEmpty {
            let codes = (try? await DetectBarcodesRequest().perform(on: image)) ?? []
            result.barcodes = codes.compactMap(\.payloadString)
        }
        result.barcodes = result.barcodes.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }

        let total = result.lines.reduce(0) { $0 + $1.text.count }
        let inTables = result.tables.reduce(0) { sum, table in
            sum + table.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
        }
        result.tableShare = total > 0 ? min(1, Double(inTables) / Double(total)) : 0
        return result
    }

    private static func readLines(_ image: CGImage, size: CGSize) async throws -> [TextLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        return try await request.perform(on: image).compactMap { line(from: $0, size: size) }
    }

    private static func line(from observation: RecognizedTextObservation, size: CGSize) -> TextLine? {
        guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
        let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
        return TextLine(text: text, box: box)
    }

    /// A table as a grid. A cell that spans columns fills its first column.
    private static func cells(of table: DocumentObservation.Container.Table) -> [[String]] {
        let width = table.rows.flatMap { $0.map { $0.columnRange.upperBound + 1 } }.max() ?? 0
        let height = table.rows.flatMap { $0.map { $0.rowRange.upperBound + 1 } }.max() ?? 0
        guard width > 0, height > 0 else { return [] }
        var grid = Array(repeating: Array(repeating: "", count: width), count: height)
        for row in table.rows {
            for cell in row {
                let text = cell.content.text.transcript
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                grid[cell.rowRange.lowerBound][cell.columnRange.lowerBound] = text
            }
        }
        return grid.filter { $0.contains { !$0.isEmpty } }
    }
}
