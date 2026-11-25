import PDFKit
import XCTest

/// Indexes the sample lease with the real engine (no AI) and checks search,
/// the scanned page, tables and highlighting.
final class EngineTests: XCTestCase {
    private var folder: URL!
    private var pdf: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "pagewise-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pdf = folder.appending(path: "Sample Lease.pdf")
        SamplePDF.write(to: pdf)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func indexed() async throws -> (Engine, Int64) {
        let engine = Engine(path: folder.appending(path: "test.sqlite"))
        let added = await engine.add(pdf)
        let id = try XCTUnwrap(added)
        let pages = try await engine.begin(id)
        XCTAssertEqual(pages, 5)
        for page in 0..<pages { try await engine.indexPage(id, page: page) }
        await engine.finish(id)
        return (engine, id)
    }

    func testSearchFindsTheRightPage() async throws {
        let (engine, id) = try await indexed()
        let rows = await engine.documents()
        XCTAssertEqual(rows.first?.status, .ready)

        let rent = await engine.search("How much is the monthly rent?", docs: [id])
        XCTAssertEqual(rent.first?.page, 1, rent.map { "\($0.page): \($0.text.prefix(60))" }.joined(separator: "\n"))

        let notice = await engine.search("How much notice to end the lease?", docs: [id])
        XCTAssertEqual(notice.prefix(2).contains { $0.page == 2 }, true)

        // Page 5 has no text layer: it was read as a picture.
        let pets = await engine.search("Can I keep a cat?", docs: [id])
        XCTAssertEqual(pets.first?.page, 4, pets.map { "\($0.page): \($0.text.prefix(60))" }.joined(separator: "\n"))
        XCTAssertTrue(pets.first?.text.contains("small dog") == true)
    }

    func testChangedFileIsQueuedAgain() async throws {
        let (engine, id) = try await indexed()
        try await Task.sleep(for: .seconds(1.1))
        SamplePDF.write(to: pdf)  // a new modification date
        let again = await engine.add(pdf)
        XCTAssertEqual(again, id)
        let row = await engine.documents().first
        XCTAssertEqual(row?.status, .queued)
        let hits = await engine.search("rent", docs: [id])
        XCTAssertTrue(hits.isEmpty)
    }

    func testFindsTheTable() async throws {
        let (engine, id) = try await indexed()
        let tables = try await engine.scanTables(of: id) { _ in }
        let table = try XCTUnwrap(tables.first { $0.page == 3 }, "\(tables)")
        XCTAssertTrue(table.rows.contains { $0.first == "Electricity" }, "\(table.rows)")
    }

    func testHighlightFindsQuoteOnPage() throws {
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        let page = try XCTUnwrap(document.page(at: 2))
        let quote = "Either party may end this lease by giving 60 days of written notice to the other party."
        let selection = try XCTUnwrap(ReaderFinder.find(quote, on: page, in: document))
        XCTAssertEqual(selection.string?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces), quote)
    }
}
