#if DEBUG
import AppKit
import Darwin

/// Debug builds only. scripts/selftest.sh starts it.
///
/// 1. Indexes the sample lease in a separate, temporary library and asks
///    questions with known answers, including two whose answers are not in
///    the PDF. Each answer must cite the right page, or say it can't find it.
/// 2. Adds the sample to the real library, asks one question in the window,
///    opens the quote, saves pictures of the windows, then removes the sample.
///
/// It writes SELFTEST lines to the log. It never logs your own PDFs.
@MainActor
final class SelfTest {
    private var failures: [String] = []

    init() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.barrynapier.pagewise.selftest"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    private func start() {
        Task { await run() }
    }

    private func check(_ ok: Bool, _ name: String) {
        Log.shared.add("SELFTEST \(ok ? "ok  " : "FAIL") \(name)")
        if !ok { failures.append(name) }
    }

    struct Case {
        let question: String
        /// The page that must be cited (from 0), or nil when the answer is not in the PDF.
        let page: Int?
        /// Words the answer should contain.
        let words: [String]
    }

    static let cases = [
        Case(question: "How much is the rent?", page: 1, words: ["1,450"]),
        Case(question: "How much notice do I need to give to end the lease?", page: 2, words: ["60"]),
        Case(question: "When is the deposit returned?", page: 2, words: ["21"]),
        Case(question: "Can I keep a cat?", page: 4, words: []),
        Case(question: "Who pays for the internet?", page: 3, words: ["tenant"]),
        Case(question: "What is the landlord's phone number?", page: nil, words: []),
        Case(question: "What is the capital of France?", page: nil, words: []),
    ]

    private func run() async {
        failures = []
        Log.shared.add("SELFTEST start")
        if let message = Asker.unavailableMessage {
            Log.shared.add("SELFTEST skip: \(message)")
            return
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "pagewise-selftest")
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appending(path: "Sample Lease.pdf")
        SamplePDF.write(to: pdf)

        // 1. Questions with known answers.
        let engine = Engine(path: folder.appending(path: "selftest.sqlite"))
        guard let id = await engine.add(pdf), let pages = try? await engine.begin(id) else {
            check(false, "index the sample")
            return
        }
        let indexStart = Date()
        for page in 0..<pages { try? await engine.indexPage(id, page: page) }
        await engine.finish(id)
        Log.shared.add("SELFTEST indexed \(pages) pages in \(String(format: "%.1f", Date().timeIntervalSince(indexStart)))s")

        var right = 0
        for item in Self.cases {
            let started = Date()
            var final: ChatMessage?
            for await update in Asker.ask(item.question, docs: [id], titles: [id: "Sample Lease"], previous: nil, language: nil, engine: engine) {
                if case .done(let message) = update { final = message }
            }
            guard let message = final else {
                check(false, "\(item.question): no answer")
                continue
            }
            let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
            let pagesCited = message.citations.map { $0.page }
            let ok: Bool
            if let page = item.page {
                let hasWords = item.words.allSatisfy { message.text.lowercased().contains($0.lowercased()) }
                ok = message.outcome == .answered && pagesCited.contains(page) && hasWords
            } else {
                ok = message.outcome != .answered
            }
            if ok { right += 1 }
            check(ok, "“\(item.question)” → \(message.outcome.rawValue), pages \(pagesCited.map { $0 + 1 }), \(seconds)s")
            Log.shared.add("SELFTEST answer: \(message.text.prefix(200).replacingOccurrences(of: "\n", with: " ⏎ "))")
            for citation in message.citations {
                Log.shared.add("SELFTEST quote p\(citation.page + 1): \(citation.quote.prefix(120))")
            }
            if let unchecked = message.uncheckedText {
                Log.shared.add("SELFTEST unchecked: \(unchecked.prefix(160))")
            }
        }
        Log.shared.add("SELFTEST score \(right)/\(Self.cases.count)")

        // A summary of the whole PDF.
        let summary = await Asker.summarize(doc: id, title: "Sample Lease", language: nil, engine: engine) { _ in }
        check(summary.outcome == .summary && summary.text.contains("1,450"), "summary mentions the rent")
        Log.shared.add("SELFTEST summary: \(summary.text.prefix(300).replacingOccurrences(of: "\n", with: " ⏎ "))")

        // 2. The real window, for pictures.
        await showInWindow(pdf)
        Log.shared.add(failures.isEmpty ? "SELFTEST PASS" : "SELFTEST FAIL \(failures.count) check(s)")
    }

    private func showInWindow(_ source: URL) async {
        let library = Library.shared
        let samples = Engine.folder.appending(path: "Self-test")
        try? FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        let pdf = samples.appending(path: "Sample Lease.pdf")
        try? FileManager.default.removeItem(at: pdf)
        try? FileManager.default.copyItem(at: source, to: pdf)
        guard let id = await library.add([pdf]).first else { return check(false, "add sample to library") }
        AppDelegate.shared?.openLibrary?()
        library.selectRequest = id
        for _ in 0..<60 where library.document(id)?.status != .ready {
            try? await Task.sleep(for: .milliseconds(500))
        }
        let chat = Chats.model(for: .docs([id]))
        await chat.load()
        for question in ["How much is the rent, and is there a late fee?", "How much notice do I need to give to end the lease?"] {
            chat.send(question)
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<60 where chat.isWorking { try? await Task.sleep(for: .milliseconds(500)) }
        }
        if let citation = chat.messages.last?.citations.first { library.open(citation) }
        try? await Task.sleep(for: .seconds(1.5))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(600))
            Self.snapshotWindows(suffix: appearance == .aqua ? "light" : "dark")
        }
        NSApp.appearance = nil
        if ProcessInfo.processInfo.environment["PAGEWISE_KEEP_SAMPLE"] == nil {
            await chat.clear()
            await library.remove([id])
            try? FileManager.default.removeItem(at: samples)
        }
    }

    private typealias WindowImageFunction = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    static func windowImage(_ number: Int) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let function = unsafeBitCast(symbol, to: WindowImageFunction.self)
        // .null rect, optionIncludingWindow (1 << 3), bestResolution | boundsIgnoreFraming.
        return function(.null, 1 << 3, UInt32(number), (1 << 3) | (1 << 0))?.takeRetainedValue()
    }

    /// Saves a PNG of each visible window to ~/Library/Logs/Pagewise/shots.
    static func snapshotWindows(suffix: String) {
        let folder = Log.shared.fileURL.deletingLastPathComponent().appending(path: "shots")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 200 {
            let name = (window.title.isEmpty ? "window-\(index)" : window.title).replacingOccurrences(of: " ", with: "-")
            let url = folder.appending(path: "\(name)-\(suffix).png")
            // The window server's own picture shows what people see, with
            // see-through sidebars. An app may picture its own windows
            // without Screen Recording. The old call is hidden from Swift
            // in newer SDKs, so it is looked up by name.
            if let image = Self.windowImage(window.windowNumber),
               let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                Log.shared.add("SELFTEST shot \(name)-\(suffix).png")
                continue
            }
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            Log.shared.add("SELFTEST shot \(name)-\(suffix).png")
        }
    }
}
#endif
