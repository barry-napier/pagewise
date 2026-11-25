import AppKit
import IOKit.ps
import Observation

/// Where the reader should go: a page, and a sentence to highlight.
struct ReaderFocus: Equatable {
    let doc: Int64
    let page: Int
    let quote: String?
    /// Changes on every jump, so clicking the same quote twice still jumps.
    let token = UUID()
}

/// The library as the windows see it. Indexes queued PDFs one at a time
/// in the background, a page at a time.
@MainActor
@Observable
final class Library {
    static let shared = Library()

    let engine = Engine()
    private(set) var documents: [DocumentRow] = []
    private(set) var pausedForBattery = false
    var focus: ReaderFocus?
    /// A PDF to select in the sidebar, set from outside the window.
    var selectRequest: Int64?

    @ObservationIgnored private var worker: Task<Void, Never>?

    var titles: [Int64: String] {
        Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0.title) })
    }

    func document(_ id: Int64) -> DocumentRow? {
        documents.first { $0.id == id }
    }

    func document(path: String) -> DocumentRow? {
        let standard = URL(fileURLWithPath: path).standardizedFileURL.path
        return documents.first { $0.path == standard }
    }

    var isIndexing: Bool {
        documents.contains { $0.status == .queued || $0.status == .indexing }
    }

    func load() async {
        documents = await engine.documents()
        startWorker()
    }

    func refresh() async {
        documents = await engine.documents()
    }

    // MARK: - Changes

    /// Adds PDFs, or every PDF inside folders. Returns the ids added.
    @discardableResult
    func add(_ urls: [URL], folder: String? = nil) async -> [Int64] {
        var ids: [Int64] = []
        for url in Self.pdfs(in: urls) {
            if let id = await engine.add(url, folder: folder) { ids.append(id) }
        }
        await refresh()
        startWorker()
        return ids
    }

    func remove(_ ids: Set<Int64>) async {
        for id in ids { await engine.remove(id) }
        await refresh()
    }

    func reindex(_ id: Int64) async {
        await engine.reindex(id)
        await refresh()
        startWorker()
    }

    func deleteEverything() async {
        worker?.cancel()
        worker = nil
        await engine.deleteEverything()
        await refresh()
        Log.shared.add("Deleted the whole index")
    }

    /// Lets the user pick PDFs or folders to add.
    func pickAndAdd() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Pick PDFs, or folders of PDFs."
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await add(urls) }
        }
    }

    func open(_ citation: Citation) {
        focus = ReaderFocus(doc: citation.doc, page: citation.page, quote: citation.quote)
    }

    // MARK: - Indexing

    func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !Task.isCancelled {
                guard let next = documents.first(where: { $0.status == .queued || $0.status == .indexing }) else { break }
                if Prefs.shared.pauseOnBattery, Self.onBattery {
                    pausedForBattery = true
                    try? await Task.sleep(for: .seconds(30))
                    continue
                }
                pausedForBattery = false
                await index(next)
            }
            pausedForBattery = false
            worker = nil
        }
    }

    private func index(_ row: DocumentRow) async {
        let started = Date()
        do {
            let pages = try await engine.begin(row.id)
            await refresh()
            for page in 0..<pages {
                if Task.isCancelled { return }
                if Prefs.shared.pauseOnBattery, Self.onBattery {
                    pausedForBattery = true
                    try? await Task.sleep(for: .seconds(30))
                }
                guard document(row.id) != nil else { return }  // removed meanwhile
                try await engine.indexPage(row.id, page: page)
                if let index = documents.firstIndex(where: { $0.id == row.id }) {
                    documents[index].indexedPages = page + 1
                    documents[index].status = .indexing
                }
            }
            await engine.finish(row.id)
            Log.shared.add("Indexed a PDF: \(pages) pages in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        } catch {
            await engine.fail(row.id, error)
            Log.shared.add("Could not index a PDF: \(error.localizedDescription)")
        }
        await refresh()
    }

    // MARK: - Helpers

    static var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }

    /// The PDFs among these files, looking inside folders up to four levels deep.
    static func pdfs(in urls: [URL]) -> [URL] {
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if !isFolder.boolValue {
                if url.pathExtension.lowercased() == "pdf" { found.append(url) }
                continue
            }
            let baseDepth = url.pathComponents.count
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let item = enumerator?.nextObject() as? URL {
                if item.pathComponents.count - baseDepth > 4 {
                    enumerator?.skipDescendants()
                    continue
                }
                if item.pathExtension.lowercased() == "pdf" { found.append(item) }
            }
        }
        return found
    }
}

/// Watches folders the user picked and keeps the library in step with them.
@MainActor
final class FolderWatcher {
    static let shared = FolderWatcher()
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?

    /// Starts watching the folders in Settings, after one full scan.
    func restart() {
        stop()
        let folders = Prefs.shared.watchedFolders.filter { FileManager.default.fileExists(atPath: $0) }
        guard !folders.isEmpty else { return }
        Task { await scan(folders) }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.changed() }
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, folders as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
        Log.shared.add("Watching \(folders.count) folder\(folders.count == 1 ? "" : "s")")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func changed() {
        // Wait for a quiet moment, so a file still downloading is read once.
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await scan(Prefs.shared.watchedFolders)
        }
    }

    private func scan(_ folders: [String]) async {
        for folder in folders {
            await Library.shared.add([URL(fileURLWithPath: folder)], folder: folder)
            _ = await Library.shared.engine.removeMissing(inFolder: folder)
        }
        await Library.shared.refresh()
    }
}

/// Asks Preview which PDF is open in its front window.
@MainActor
enum PreviewBridge {
    static let bundleID = "com.apple.Preview"

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// The file of Preview's front document, if it is a PDF. macOS asks the
    /// user once before letting Pagewise ask Preview.
    static func frontPDF() -> URL? {
        let script = NSAppleScript(source: "tell application id \"com.apple.Preview\" to return path of front document")
        var error: NSDictionary?
        guard let path = script?.executeAndReturnError(&error).stringValue else {
            if let error { Log.shared.add("Could not ask Preview: \(error[NSAppleScript.errorMessage] ?? "unknown")") }
            return nil
        }
        let url = URL(fileURLWithPath: path)
        return url.pathExtension.lowercased() == "pdf" ? url : nil
    }
}
