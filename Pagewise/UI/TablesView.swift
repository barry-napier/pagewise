import SwiftUI
import UniformTypeIdentifiers

/// The tables in one PDF, ready to copy or save as a spreadsheet file.
struct TablesView: View {
    let doc: Int64
    @State private var tables: [FoundTable] = []
    @State private var progress: Double?
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    private let library = Library.shared

    private var row: DocumentRow? { library.document(doc) }

    var body: some View {
        Group {
            if let progress {
                VStack(spacing: 12) {
                    ProgressView(value: progress) { Text("Looking for tables, page by page…") }
                        .frame(maxWidth: 300)
                    Button("Stop") { task?.cancel() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if row?.tablesScanned != true {
                ContentUnavailableView {
                    Label("Find the tables in this PDF", systemImage: "tablecells")
                } description: {
                    Text("Pagewise looks at every page with Apple's document reader. It takes about a second per page.")
                } actions: {
                    Button("Find Tables", action: scan).buttonStyle(.borderedProminent)
                }
            } else if tables.isEmpty {
                ContentUnavailableView {
                    Label("No tables found", systemImage: "tablecells")
                } actions: {
                    Button("Look Again", action: scan)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(tables) { table in TableCard(table: table, doc: doc, title: row?.title ?? "Table") }
                    }
                    .padding(16)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let message {
                Text(message).font(.callout).padding(8).background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .task(id: doc) { tables = await library.engine.tables(of: doc) }
    }

    private func scan() {
        progress = 0
        let engine = library.engine
        task = Task {
            do {
                tables = try await engine.scanTables(of: doc) { value in
                    Task { @MainActor in progress = value }
                }
                Log.shared.add("Found \(tables.count) tables")
            } catch is CancellationError {
            } catch {
                message = error.localizedDescription
            }
            progress = nil
            await library.refresh()
        }
    }
}

private struct TableCard: View {
    let table: FoundTable
    let doc: Int64
    let title: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Page \(table.page + 1)\(table.index > 0 ? ", table \(table.index + 1)" : "")")
                    .font(.headline)
                Text("\(table.rows.count) rows").foregroundStyle(.secondary)
                Spacer()
                Button("Show Page") {
                    Library.shared.focus = ReaderFocus(doc: doc, page: table.page, quote: nil)
                }
                Button(copied ? "Copied" : "Copy as CSV") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.csv(table.rows), forType: .string)
                    copied = true
                }
                Button("Save…", action: save)
            }
            .controlSize(.small)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.prefix(12).enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 12, weight: index == 0 ? .semibold : .regular))
                                    .lineLimit(2)
                                    .frame(maxWidth: 220, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .border(Color.secondary.opacity(0.2), width: 0.5)
                            }
                        }
                    }
                }
            }
            if table.rows.count > 12 {
                Text("and \(table.rows.count - 12) more rows").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(title) page \(table.page + 1).csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? Self.csv(table.rows).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func csv(_ rows: [[String]]) -> String {
        rows.map { row in
            row.map { cell in
                cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
                    ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
            }.joined(separator: ",")
        }.joined(separator: "\n")
    }
}
