import SwiftUI

/// A conversation with one PDF, several, or the whole library.
struct ChatView: View {
    @Bindable var model: ChatModel
    let scope: ChatScope
    @FocusState private var focused: Bool
    private let library = Library.shared

    private var notReady: [DocumentRow] {
        let docs = scope.docIDs.map { ids in library.documents.filter { ids.contains($0.id) } } ?? library.documents
        return docs.filter { $0.status != .ready && $0.status != .failed }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if library.documents.isEmpty && model.messages.isEmpty {
                            emptyLibrary
                        } else if model.messages.isEmpty && !model.isWorking {
                            suggestions
                        }
                        ForEach(model.messages) { message in
                            MessageView(message: message).id(message.id)
                        }
                        if model.isWorking { working.id("working") }
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.count) { scrollDown(proxy) }
                .onChange(of: model.partial) { scrollDown(proxy) }
            }
            if !notReady.isEmpty { indexingNote }
            if let message = Asker.unavailableMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).padding(10)
            }
            Divider()
            inputBar
        }
        .task { await model.load() }
        .onAppear { focused = true }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            if model.isWorking { proxy.scrollTo("working", anchor: .bottom) }
            else if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("Add your first PDFs", systemImage: "doc.badge.plus")
        } description: {
            Text("Drop PDFs or folders on the sidebar, or pick them here. Or let Pagewise watch a folder, like Downloads, and add new PDFs by itself.")
        } actions: {
            Button("Add PDFs…") { library.pickAndAdd() }
                .buttonStyle(.borderedProminent)
            SettingsLink { Text("Watch a Folder…") }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(scope.singleDoc != nil ? "Ask about this PDF" : scope == .library ? "Ask your whole library" : "Ask about these PDFs")
                .font(.title3.weight(.semibold))
            Text("Answers come with the exact sentences they are based on. If the answer is not in the PDFs, Pagewise says so.")
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                if scope.singleDoc != nil {
                    Button { model.summarize() } label: { Label("Summarize this PDF", systemImage: "text.badge.star") }
                    Button("What is this about?") { model.send("What is this document about?") }
                    Button("What are the key dates?") { model.send("What are the key dates and deadlines?") }
                    Button("Who is involved?") { model.send("Which people and organisations are named, and what is their role?") }
                } else {
                    Button("Which PDFs mention a deadline?") { model.send("Which documents mention a deadline, and what is it?") }
                    Button("What amounts of money are mentioned?") { model.send("What amounts of money are mentioned, and what are they for?") }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }

    private var working: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let partial = model.partial, !partial.isEmpty {
                Text(partial).textSelection(.enabled)
                Text("Checking quotes…").font(.caption).foregroundStyle(.secondary)
            } else if let progress = model.summaryProgress {
                ProgressView(value: progress) { Text(model.status ?? "Summing up…").font(.callout) }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.status ?? "Thinking…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var indexingNote: some View {
        let pages = notReady.reduce(0) { $0 + $1.indexedPages }
        let total = notReady.reduce(0) { $0 + $1.pages }
        return HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(total > 0
                 ? "Still indexing (\(pages) of \(total) pages). You can ask about the pages already done."
                 : "Still indexing. You can ask about the pages already done.")
                .font(.callout)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask a question…", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { model.send() }
                .padding(8)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            if model.isWorking {
                Button { model.stop() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .help("Stop")
            } else {
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Ask (Return)")
            }
            Menu {
                if scope.singleDoc != nil {
                    Button("Summarize this PDF") { model.summarize() }
                }
                Button("Clear Chat", role: .destructive) { Task { await model.clear() } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
    }
}

/// One message: a question, or an answer with its proof.
struct MessageView: View {
    let message: ChatMessage
    var compact = false
    @State private var showUnchecked = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                answerText
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.citations) { CitationView(citation: $0) }
                    }
                }
                if message.outcome == .unchecked, let unchecked = message.uncheckedText {
                    DisclosureGroup("Show the unchecked answer", isExpanded: $showUnchecked) {
                        Text(unchecked)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .font(.callout)
                }
                if !message.closest.isEmpty, message.outcome != .answered {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Closest pages").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(message.closest) { citation in
                                Button("\(citation.title), page \(citation.page + 1)") {
                                    Library.shared.focus = ReaderFocus(doc: citation.doc, page: citation.page, quote: nil)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                if !message.searched.isEmpty, !compact {
                    Label("Searched " + message.searched.joined(separator: "; "), systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var answerText: some View {
        switch message.outcome {
        case .answered, .summary:
            Text(rich(message.text)).textSelection(.enabled)
        case .notFound, .unchecked:
            Label(message.text, systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .failed:
            Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }
}

/// A checked quote. Click it to open the page with the sentence highlighted.
struct CitationView: View {
    let citation: Citation
    @Environment(\.citationAction) private var action

    var body: some View {
        Button {
            if let action { action.run(citation) } else { Library.shared.open(citation) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text("“\(citation.quote)”")
                        .italic()
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                    Text("\(citation.title) · page \(citation.page + 1)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open page \(citation.page + 1) with this sentence highlighted")
    }
}

/// Light Markdown from the model: **bold**, `code`, and "* " bullets.
func rich(_ text: String) -> AttributedString {
    let bulleted = text.replacing(#/(?m)^(\s*)[*-]\s/#) { "\($0.1)• " }
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return (try? AttributedString(markdown: bulleted, options: options)) ?? AttributedString(text)
}

/// Lays out views in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
