import AppKit
import SwiftUI

/// The Spotlight-style box from the shortcut. It asks the PDF open in
/// Preview, if Preview is in front, or else the whole library.
@MainActor
@Observable
final class AskBoxModel {
    var question = ""
    private(set) var scope: ChatScope = .library
    private(set) var scopeName = "All PDFs"
    private(set) var note: String?
    private(set) var answer: ChatMessage?
    private(set) var partial: String?
    private(set) var working = false
    private var task: Task<Void, Never>?

    /// Picks what to ask, before the box shows.
    func prepare(previewPDF: URL?) async {
        task?.cancel()
        answer = nil
        partial = nil
        working = false
        note = nil
        let library = Library.shared
        if let url = previewPDF {
            var row = library.document(path: url.path)
            if row == nil {
                await library.add([url])
                row = library.document(path: url.path)
                note = "Added to your library. Indexing now; you can ask about pages already done."
            }
            if let row {
                scope = .docs([row.id])
                scopeName = "\(row.title) (open in Preview)"
                return
            }
        }
        scope = .library
        let count = library.documents.count
        scopeName = "All PDFs (\(count))"
        if count == 0 { note = "Your library is empty. Add PDFs in the Pagewise window, or open one in Preview first." }
    }

    func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        task?.cancel()
        working = true
        answer = nil
        partial = nil
        let library = Library.shared
        let scope = scope
        task = Task {
            let stream = Asker.ask(
                text, docs: scope.docIDs, titles: library.titles, previous: nil,
                language: Prefs.shared.languageForAnswers, engine: library.engine)
            for await update in stream {
                switch update {
                case .searching: break
                case .writing(let value): partial = value
                case .done(let message):
                    partial = nil
                    answer = message
                    // Keep it in that scope's chat too.
                    Chats.model(for: scope).record(question: text, answer: message)
                }
            }
            working = false
        }
    }
}

@MainActor
final class AskBoxController {
    let model = AskBoxModel()
    private var panel: AskPanel?
    var openLibrary: (() -> Void)?

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { return close() }
        let preview = PreviewBridge.isFrontmost ? PreviewBridge.frontPDF() : nil
        Task {
            await model.prepare(previewPDF: preview)
            show()
        }
    }

    private func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 640
        let frame = screen.visibleFrame
        panel.setFrame(CGRect(x: frame.midX - width / 2, y: frame.maxY - frame.height * 0.22 - 420, width: width, height: 420), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> AskPanel {
        let panel = AskPanel()
        panel.onEscape = { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: AskBoxView(model: model) { [weak self] citation in
            Library.shared.open(citation)
            self?.close()
            self?.openLibrary?()
        })
        return panel
    }
}

private final class AskPanel: NSPanel {
    var onEscape: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func resignKey() {
        super.resignKey()
        // Like Spotlight: clicking elsewhere closes it.
        onEscape?()
    }
}

private struct AskBoxView: View {
    @Bindable var model: AskBoxModel
    let openCitation: @MainActor @Sendable (Citation) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(.tint)
                TextField("Ask your PDFs…", text: $model.question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                    .onSubmit { model.ask() }
                if model.working { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "scope")
                Text("Asking: \(model.scopeName)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            if let note = model.note {
                Text(note).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.bottom, 8)
            }
            if model.answer != nil || model.partial != nil {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let answer = model.answer {
                            MessageView(message: answer, compact: true)
                                .environment(\.openURL, OpenURLAction { _ in .handled })
                            if !answer.citations.isEmpty {
                                Text("Click a quote to open the page in Pagewise.")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                        } else if let partial = model.partial {
                            Text(partial).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .environment(\.citationAction, CitationAction(run: openCitation))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 640, height: 420, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear { focused = true }
    }
}

/// Lets a citation inside the ask box close the box when clicked.
struct CitationAction: Sendable {
    let run: @MainActor @Sendable (Citation) -> Void
}

extension EnvironmentValues {
    @Entry var citationAction: CitationAction? = nil
}
