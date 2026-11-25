import SwiftUI
import UniformTypeIdentifiers

/// The main window: PDFs on the left, the chat in the middle, the PDF on
/// the right.
struct LibraryView: View {
    enum Item: Hashable {
        case all
        case doc(Int64)
    }

    @State private var selection: Set<Item> = [.all]
    @State private var dropping = false
    private let library = Library.shared

    private var scope: ChatScope {
        let docs = selection.compactMap { item -> Int64? in
            if case .doc(let id) = item { return id }
            return nil
        }
        if selection.contains(.all) || docs.isEmpty { return .library }
        return .docs(docs.sorted())
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ChatColumn(scope: scope)
                .id(scope.key)
                .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 720)
        } detail: {
            ReaderColumn(scope: scope)
        }
        .navigationTitle(title)
        .onChange(of: library.selectRequest) {
            if let id = library.selectRequest {
                selection = [.doc(id)]
                library.selectRequest = nil
            }
        }
        .onChange(of: library.focus) {
            // A quote from the ask box: show its PDF.
            if let focus = library.focus, !scopeContains(focus.doc) { selection = [.doc(focus.doc)] }
        }
        .frame(minWidth: 900, minHeight: 560)
    }

    private var title: String {
        switch scope {
        case .library: "All PDFs"
        case .docs(let ids) where ids.count == 1: library.document(ids[0])?.title ?? "PDF"
        case .docs(let ids): "\(ids.count) PDFs"
        }
    }

    private func scopeContains(_ doc: Int64) -> Bool {
        switch scope {
        case .library: true
        case .docs(let ids): ids.contains(doc)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("All PDFs", systemImage: "books.vertical")
                .badge(library.documents.count)
                .tag(Item.all)
            Section("PDFs") {
                ForEach(library.documents) { doc in
                    DocumentRowView(doc: doc)
                        .tag(Item.doc(doc.id))
                        .contextMenu { menu(for: doc) }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { await add(providers) }
            return true
        }
        .safeAreaInset(edge: .bottom) {
            if library.isIndexing || library.pausedForBattery {
                IndexingFooter()
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: addPDFs) { Label("Add PDFs", systemImage: "plus") }
                    .help("Add PDFs or folders")
            }
        }
    }

    @ViewBuilder
    private func menu(for doc: DocumentRow) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
        Button("Open in Preview") {
            NSWorkspace.shared.open([doc.url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Preview.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        Button("Index Again") { Task { await library.reindex(doc.id) } }
        Divider()
        Button("Remove from Pagewise", role: .destructive) {
            Task {
                let ids = selection.compactMap { item -> Int64? in
                    if case .doc(let id) = item { return id }
                    return nil
                }
                await library.remove(ids.contains(doc.id) ? Set(ids) : [doc.id])
                selection = [.all]
            }
        }
    }

    private func addPDFs() { Library.shared.pickAndAdd() }

    private func add(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let fileURL = URL(dataRepresentation: url, relativeTo: nil) {
                urls.append(fileURL)
            }
        }
        await library.add(urls)
    }
}

private struct DocumentRowView: View {
    let doc: DocumentRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: doc.folder == nil ? "doc.text" : "folder.badge.gearshape")
                .foregroundStyle(.secondary)
                .help(doc.folder.map { "From \($0)" } ?? "")
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).lineLimit(1)
                switch doc.status {
                case .ready:
                    Text("\(doc.pages) page\(doc.pages == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                case .indexing:
                    ProgressView(value: doc.progress).controlSize(.mini)
                case .queued:
                    Text("Waiting to index").font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text(doc.error ?? "Could not index").font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
    }
}

private struct IndexingFooter: View {
    private let library = Library.shared

    var body: some View {
        HStack(spacing: 8) {
            if library.pausedForBattery {
                Image(systemName: "battery.50")
                Text("Indexing paused on battery").font(.caption)
            } else {
                ProgressView().controlSize(.small)
                let waiting = library.documents.filter { $0.status == .queued || $0.status == .indexing }.count
                Text("Indexing \(waiting) PDF\(waiting == 1 ? "" : "s")…").font(.caption)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(10)
        .background(.bar)
    }
}

/// The chat, and for one PDF a Tables tab.
private struct ChatColumn: View {
    let scope: ChatScope
    @State private var tab = Tab.chat

    enum Tab: String, CaseIterable {
        case chat = "Chat"
        case tables = "Tables"
    }

    var body: some View {
        VStack(spacing: 0) {
            if scope.singleDoc != nil {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.vertical, 8)
            }
            if tab == .tables, let doc = scope.singleDoc {
                TablesView(doc: doc)
            } else {
                ChatView(model: Chats.model(for: scope), scope: scope)
            }
        }
    }
}

/// The PDF: the clicked quote's, or the only one picked.
private struct ReaderColumn: View {
    let scope: ChatScope
    private let library = Library.shared

    private var readerDoc: Int64? {
        if let focus = library.focus {
            switch scope {
            case .library: return focus.doc
            case .docs(let ids) where ids.contains(focus.doc): return focus.doc
            default: break
            }
        }
        return scope.singleDoc ?? scope.docIDs?.first
    }

    var body: some View {
        if let doc = readerDoc, let row = library.document(doc) {
            ReaderView(url: row.url, doc: doc, focus: library.focus?.doc == doc ? library.focus : nil)
                .navigationSplitViewColumnWidth(min: 320, ideal: 560)
        } else {
            ContentUnavailableView(
                "Click a quote to see it", systemImage: "text.viewfinder",
                description: Text("Answers show the sentences they came from. Click one to open the page."))
                .navigationSplitViewColumnWidth(min: 320, ideal: 560)
        }
    }
}
