import Foundation
import NaturalLanguage
import PDFKit
import SQLite3

/// One PDF in the library.
struct DocumentRow: Identifiable, Sendable, Equatable, Hashable {
    enum Status: String, Sendable {
        case queued, indexing, ready, failed
    }

    let id: Int64
    var path: String
    var title: String
    var pages: Int
    var indexedPages: Int
    var status: Status
    var error: String?
    /// The watched folder it came from, if any.
    var folder: String?
    var added: Date
    var tablesScanned: Bool

    var url: URL { URL(fileURLWithPath: path) }
    var progress: Double { pages > 0 ? Double(indexedPages) / Double(pages) : 0 }
}

/// A piece found by search.
struct Hit: Sendable, Identifiable, Equatable {
    let id: Int64
    let doc: Int64
    let page: Int
    let text: String
}

/// A table found on a page.
struct FoundTable: Sendable, Identifiable, Codable, Equatable {
    var id: String { "\(page)-\(index)" }
    let page: Int
    let index: Int
    let rows: [[String]]
}

enum EngineError: LocalizedError {
    case cannotOpen(String)
    case locked(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name): "Pagewise could not open \(name)."
        case .locked(let name): "\(name) has a password. Open it in Preview, unlock it and save a copy."
        }
    }
}

/// Everything the library stores, in one SQLite file in
/// ~/Library/Application Support/Pagewise. It reads PDFs, finds the text,
/// gives each piece a "meaning fingerprint" with Apple's on-device
/// embedding model, and searches by meaning and by words together.
///
/// It is an actor: indexing works one page per call, so questions can be
/// answered in between, even while a big PDF is being read.
actor Engine {
    static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Pagewise")

    private var db: OpaquePointer?
    private var open: [Int64: (pdf: PDFDocument, language: NLLanguage?, model: String)] = [:]
    private var models: [String: NLContextualEmbedding] = [:]
    /// Every piece's fingerprint, loaded on the first search.
    private var vectors: [(id: Int64, doc: Int64, model: String, vector: [Float])]?

    init(path: URL? = nil) {
        let file = path ?? Self.folder.appending(path: "library.sqlite")
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        if sqlite3_open(file.path, &handle) == SQLITE_OK {
            db = handle
            Self.exec(handle, """
                PRAGMA journal_mode = WAL;
                PRAGMA foreign_keys = ON;
                PRAGMA secure_delete = ON;
                CREATE TABLE IF NOT EXISTS documents (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    pages INTEGER NOT NULL DEFAULT 0,
                    indexed_pages INTEGER NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'queued',
                    error TEXT,
                    folder TEXT,
                    size INTEGER NOT NULL DEFAULT 0,
                    modified REAL NOT NULL DEFAULT 0,
                    added REAL NOT NULL,
                    tables_scanned INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS pieces (
                    id INTEGER PRIMARY KEY,
                    doc INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    page INTEGER NOT NULL,
                    text TEXT NOT NULL,
                    model TEXT NOT NULL,
                    vector BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS pieces_doc ON pieces(doc, page);
                CREATE VIRTUAL TABLE IF NOT EXISTS pieces_fts USING fts5(text, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TABLE IF NOT EXISTS messages (
                    id INTEGER PRIMARY KEY,
                    scope TEXT NOT NULL,
                    body TEXT NOT NULL,
                    date REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS messages_scope ON messages(scope, id);
                CREATE TABLE IF NOT EXISTS doc_tables (
                    doc INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                    page INTEGER NOT NULL,
                    idx INTEGER NOT NULL,
                    rows TEXT NOT NULL
                );
                """)
            // A crash mid-index leaves "indexing": start those again.
            Self.exec(handle, "UPDATE documents SET status = 'queued' WHERE status = 'indexing'")
        }
    }

    // MARK: - Documents

    func documents() -> [DocumentRow] {
        query("SELECT id, path, title, pages, indexed_pages, status, error, folder, added, tables_scanned FROM documents ORDER BY title COLLATE NOCASE") { s in
            DocumentRow(
                id: sqlite3_column_int64(s, 0), path: text(s, 1) ?? "", title: text(s, 2) ?? "",
                pages: Int(sqlite3_column_int(s, 3)), indexedPages: Int(sqlite3_column_int(s, 4)),
                status: DocumentRow.Status(rawValue: text(s, 5) ?? "") ?? .queued, error: text(s, 6),
                folder: text(s, 7), added: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)),
                tablesScanned: sqlite3_column_int(s, 9) != 0)
        }
    }

    /// Adds a PDF, or queues it again if the file changed. Returns its id.
    @discardableResult
    func add(_ url: URL, folder: String? = nil) -> Int64? {
        let path = url.standardizedFileURL.path
        // A fresh URL: a URL remembers file details it read before.
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = Int64(values?.fileSize ?? 0)
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let existing: [(Int64, Int64, Double)] = query("SELECT id, size, modified FROM documents WHERE path = ?", [path]) { s in
            (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), sqlite3_column_double(s, 2))
        }
        if let (id, oldSize, oldModified) = existing.first {
            if oldSize != size || abs(oldModified - modified) > 0.001 {
                clearIndex(id)
                run("UPDATE documents SET size = ?, modified = ?, status = 'queued', indexed_pages = 0, error = NULL, tables_scanned = 0 WHERE id = ?",
                    [size, modified, id])
            }
            return id
        }
        let title = url.deletingPathExtension().lastPathComponent
        run("INSERT INTO documents (path, title, folder, size, modified, added) VALUES (?, ?, ?, ?, ?, ?)",
            [path, title, folder, size, modified, Date().timeIntervalSince1970])
        return sqlite3_last_insert_rowid(db)
    }

    func remove(_ id: Int64) {
        clearIndex(id)
        run("DELETE FROM messages WHERE scope = ?", ["doc:\(id)"])
        run("DELETE FROM documents WHERE id = ?", [id])
        open[id] = nil
    }

    /// Removes library entries from a watched folder whose files are gone.
    func removeMissing(inFolder folder: String) -> Int {
        let rows = documents().filter { $0.folder == folder && !FileManager.default.fileExists(atPath: $0.path) }
        rows.forEach { remove($0.id) }
        return rows.count
    }

    func reindex(_ id: Int64) {
        clearIndex(id)
        run("UPDATE documents SET status = 'queued', indexed_pages = 0, error = NULL, tables_scanned = 0 WHERE id = ?", [id])
    }

    /// Deletes every PDF's index and chats. The PDFs themselves are untouched.
    func deleteEverything() {
        Self.exec(db, "DELETE FROM pieces_fts; DELETE FROM doc_tables; DELETE FROM pieces; DELETE FROM messages; DELETE FROM documents; VACUUM;")
        vectors = nil
        open.removeAll()
    }

    private func clearIndex(_ id: Int64) {
        run("DELETE FROM pieces_fts WHERE rowid IN (SELECT id FROM pieces WHERE doc = ?)", [id])
        run("DELETE FROM pieces WHERE doc = ?", [id])
        run("DELETE FROM doc_tables WHERE doc = ?", [id])
        vectors?.removeAll { $0.doc == id }
    }

    // MARK: - Indexing

    /// Opens a PDF for indexing. Returns its page count.
    func begin(_ id: Int64) throws -> Int {
        guard let row = documents().first(where: { $0.id == id }) else { throw EngineError.cannotOpen("the PDF") }
        guard let pdf = PDFDocument(url: row.url) else {
            fail(id, EngineError.cannotOpen(row.title))
            throw EngineError.cannotOpen(row.title)
        }
        if pdf.isLocked {
            fail(id, EngineError.locked(row.title))
            throw EngineError.locked(row.title)
        }
        // Pick the search model for the PDF's language from a sample.
        var sample = ""
        for index in 0..<min(pdf.pageCount, 5) { sample += pdf.page(at: index)?.string ?? "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(5000)))
        let language = recognizer.dominantLanguage
        let model = embeddingModel(for: language)
        open[id] = (pdf, language, model?.modelIdentifier ?? "none")
        run("UPDATE documents SET pages = ?, status = 'indexing' WHERE id = ?", [pdf.pageCount, id])
        return pdf.pageCount
    }

    /// Reads, splits and fingerprints one page.
    func indexPage(_ id: Int64, page index: Int) async throws {
        guard let (pdf, language, modelID) = open[id], let page = pdf.page(at: index) else { return }
        var text = page.string ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 30, let image = Self.render(page) {
            // A scanned page: read the picture.
            let read = try await TextReader.read(image)
            text = TextLayout.arrange(read.lines, keepIndent: false)
        }
        let pieces = Splitter.split([PageText(page: index, text: text)])
        let model = models[modelID]
        for piece in pieces {
            let vector = model.flatMap { embed(piece.text, with: $0, language: language) } ?? []
            insertPiece(doc: id, piece: piece, model: modelID, vector: vector)
        }
        run("UPDATE documents SET indexed_pages = ? WHERE id = ?", [index + 1, id])
    }

    func finish(_ id: Int64) {
        run("UPDATE documents SET status = 'ready', indexed_pages = pages WHERE id = ?", [id])
        open[id] = nil
    }

    func fail(_ id: Int64, _ error: Error) {
        run("UPDATE documents SET status = 'failed', error = ? WHERE id = ?", [error.localizedDescription, id])
        open[id] = nil
    }

    private func insertPiece(doc: Int64, piece: Piece, model: String, vector: [Float]) {
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        run("INSERT INTO pieces (doc, page, text, model, vector) VALUES (?, ?, ?, ?, ?)",
            [doc, piece.page, piece.text, model, data])
        let id = sqlite3_last_insert_rowid(db)
        run("INSERT INTO pieces_fts (rowid, text) VALUES (?, ?)", [id, piece.text])
        if !vector.isEmpty { vectors?.append((id, doc, model, vector)) }
    }

    // MARK: - Search

    /// Finds the pieces that best match the question, by meaning and by
    /// words. `docs` limits the search; nil searches the whole library.
    func search(_ question: String, docs: [Int64]?, limit: Int = 16) -> [Hit] {
        if vectors == nil { loadVectors() }
        let allowed = docs.map(Set.init)

        // Meaning: the question's fingerprint for each model in use.
        var byMeaning: [(Int64, Float)] = []
        var queryVectors: [String: [Float]] = [:]
        for item in vectors ?? [] where allowed?.contains(item.doc) ?? true {
            if queryVectors[item.model] == nil, let model = models[item.model] ?? loadModel(item.model) {
                queryVectors[item.model] = embed(question, with: model, language: nil) ?? []
            }
            guard let query = queryVectors[item.model], query.count == item.vector.count else { continue }
            byMeaning.append((item.id, Ranking.similarity(query, item.vector[...])))
        }
        let meaning = byMeaning.sorted { $0.1 > $1.1 }.prefix(30).map(\.0)

        // Words.
        var words: [Int64] = []
        if let match = Ranking.ftsQuery(question) {
            var sql = "SELECT f.rowid FROM pieces_fts f JOIN pieces p ON p.id = f.rowid WHERE pieces_fts MATCH ?"
            if let docs { sql += " AND p.doc IN (\(docs.map(String.init).joined(separator: ",")))" }
            sql += " ORDER BY bm25(pieces_fts) LIMIT 30"
            words = query(sql, [match]) { sqlite3_column_int64($0, 0) }
        }

        let ids = Ranking.fuse([meaning, words]).prefix(limit)
        return pieces(Array(ids))
    }

    /// Pieces by id, in the order given.
    func pieces(_ ids: [Int64]) -> [Hit] {
        guard !ids.isEmpty else { return [] }
        let rows = query("SELECT id, doc, page, text FROM pieces WHERE id IN (\(ids.map(String.init).joined(separator: ",")))") { s in
            Hit(id: sqlite3_column_int64(s, 0), doc: sqlite3_column_int64(s, 1), page: Int(sqlite3_column_int(s, 2)), text: text(s, 3) ?? "")
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        return ids.compactMap { byID[$0] }
    }

    /// Every piece of a PDF in reading order, for summaries.
    func allPieces(of doc: Int64) -> [Hit] {
        query("SELECT id, doc, page, text FROM pieces WHERE doc = ? ORDER BY page, id", [doc]) { s in
            Hit(id: sqlite3_column_int64(s, 0), doc: sqlite3_column_int64(s, 1), page: Int(sqlite3_column_int(s, 2)), text: text(s, 3) ?? "")
        }
    }

    private func loadVectors() {
        vectors = query("SELECT id, doc, model, vector FROM pieces") { s in
            let count = Int(sqlite3_column_bytes(s, 3)) / MemoryLayout<Float>.size
            var vector = [Float](repeating: 0, count: count)
            if count > 0, let bytes = sqlite3_column_blob(s, 3) {
                vector.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: count * 4)) }
            }
            return (sqlite3_column_int64(s, 0), sqlite3_column_int64(s, 1), text(s, 2) ?? "", vector)
        }.filter { !$0.3.isEmpty }
    }

    // MARK: - Meaning fingerprints

    private func embeddingModel(for language: NLLanguage?) -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(language: language ?? .english) ?? NLContextualEmbedding(language: .english) else {
            return nil
        }
        if let loaded = models[model.modelIdentifier] { return loaded }
        return prepare(model)
    }

    private func loadModel(_ identifier: String) -> NLContextualEmbedding? {
        guard let model = NLContextualEmbedding(modelIdentifier: identifier) else { return nil }
        return prepare(model)
    }

    private func prepare(_ model: NLContextualEmbedding) -> NLContextualEmbedding? {
        do {
            if !model.hasAvailableAssets {
                // Apple downloads the model the first time. Without it, word search still works.
                model.requestAssets { _, _ in }
                return nil
            }
            try model.load()
            models[model.modelIdentifier] = model
            return model
        } catch {
            return nil
        }
    }

    /// The average of the token vectors, normalised.
    private func embed(_ text: String, with model: NLContextualEmbedding, language: NLLanguage?) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var sum = [Float](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for index in 0..<min(vector.count, sum.count) { sum[index] += Float(vector[index]) }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        return Ranking.normalize(sum)
    }

    // MARK: - Tables

    func tables(of doc: Int64) -> [FoundTable] {
        query("SELECT page, idx, rows FROM doc_tables WHERE doc = ? ORDER BY page, idx", [doc]) { s in
            let rows = (try? JSONDecoder().decode([[String]].self, from: Data((text(s, 2) ?? "[]").utf8))) ?? []
            return FoundTable(page: Int(sqlite3_column_int(s, 0)), index: Int(sqlite3_column_int(s, 1)), rows: rows)
        }
    }

    /// Looks for tables on every page with Apple's document reader.
    func scanTables(of doc: Int64, progress: @Sendable (Double) -> Void) async throws -> [FoundTable] {
        guard let row = documents().first(where: { $0.id == doc }), let pdf = PDFDocument(url: row.url) else {
            throw EngineError.cannotOpen("the PDF")
        }
        run("DELETE FROM doc_tables WHERE doc = ?", [doc])
        for index in 0..<pdf.pageCount {
            try Task.checkCancellation()
            if let page = pdf.page(at: index), let image = Self.render(page) {
                let read = try await TextReader.read(image)
                for (number, table) in read.tables.enumerated() {
                    let json = String(decoding: try JSONEncoder().encode(table), as: UTF8.self)
                    run("INSERT INTO doc_tables (doc, page, idx, rows) VALUES (?, ?, ?, ?)", [doc, index, number, json])
                }
            }
            progress(Double(index + 1) / Double(max(1, pdf.pageCount)))
        }
        run("UPDATE documents SET tables_scanned = 1 WHERE id = ?", [doc])
        return tables(of: doc)
    }

    // MARK: - Chats

    func messages(scope: String) -> [Data] {
        query("SELECT body FROM messages WHERE scope = ? ORDER BY id", [scope]) { Data((text($0, 0) ?? "").utf8) }
    }

    func saveMessage(_ body: Data, scope: String) {
        run("INSERT INTO messages (scope, body, date) VALUES (?, ?, ?)",
            [scope, String(decoding: body, as: UTF8.self), Date().timeIntervalSince1970])
    }

    func clearMessages(scope: String) {
        run("DELETE FROM messages WHERE scope = ?", [scope])
    }

    // MARK: - Helpers

    /// Draws a page as a picture, at twice its size, for the text reader.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(2, 2400 / max(bounds.width, bounds.height, 1))
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    private static func exec(_ db: OpaquePointer?, _ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func run(_ sql: String, _ values: [Any?] = []) {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        bind(statement, values)
        sqlite3_step(statement)
    }

    private func query<T>(_ sql: String, _ values: [Any?] = [], row: (OpaquePointer?) -> T) -> [T] {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        bind(statement, values)
        var rows: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { rows.append(row(statement)) }
        return rows
    }

    private func bind(_ statement: OpaquePointer?, _ values: [Any?]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Int64: sqlite3_bind_int64(statement, index, value)
            case let value as Double: sqlite3_bind_double(statement, index, value)
            case let value as Data:
                _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), SQLITE_TRANSIENT) }
            default: sqlite3_bind_null(statement, index)
            }
        }
    }
}

private func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
