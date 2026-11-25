import Foundation
import Observation

/// What a chat asks about.
enum ChatScope: Hashable, Sendable {
    case library
    case docs([Int64])

    /// Where its messages are saved.
    var key: String {
        switch self {
        case .library: "all"
        case .docs(let ids) where ids.count == 1: "doc:\(ids[0])"
        case .docs(let ids): "docs:" + ids.sorted().map(String.init).joined(separator: ",")
        }
    }

    var docIDs: [Int64]? {
        if case .docs(let ids) = self { return ids }
        return nil
    }

    var singleDoc: Int64? {
        if case .docs(let ids) = self, ids.count == 1 { return ids[0] }
        return nil
    }
}

/// One conversation: its messages, the question being typed, and the
/// answer being written.
@MainActor
@Observable
final class ChatModel {
    let scope: ChatScope
    private(set) var messages: [ChatMessage] = []
    var draft = ""
    private(set) var isWorking = false
    /// The answer so far, while the model writes it.
    private(set) var partial: String?
    private(set) var status: String?
    /// 0 to 1 while summing up.
    private(set) var summaryProgress: Double?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loaded = false

    init(scope: ChatScope) {
        self.scope = scope
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        let decoder = JSONDecoder()
        messages = await Library.shared.engine.messages(scope: scope.key)
            .compactMap { try? decoder.decode(ChatMessage.self, from: $0) }
    }

    func send(_ text: String? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isWorking else { return }
        draft = ""
        append(ChatMessage(role: .user, text: question))
        let previous = lastExchange()
        isWorking = true
        status = "Searching…"
        partial = nil
        let library = Library.shared
        task = Task {
            let stream = Asker.ask(
                question, docs: scope.docIDs, titles: library.titles, previous: previous,
                language: Prefs.shared.languageForAnswers, engine: library.engine)
            for await update in stream {
                switch update {
                case .searching:
                    status = "Searching…"
                case .writing(let text):
                    status = nil
                    partial = text
                case .done(let message):
                    partial = nil
                    append(message)
                }
            }
            finish()
        }
    }

    func summarize() {
        guard let doc = scope.singleDoc, !isWorking, let row = Library.shared.document(doc) else { return }
        append(ChatMessage(role: .user, text: "Summarize this PDF"))
        isWorking = true
        summaryProgress = 0
        status = "Summing up each part…"
        let engine = Library.shared.engine
        task = Task {
            let message = await Asker.summarize(
                doc: doc, title: row.title, language: Prefs.shared.languageForAnswers, engine: engine
            ) { value in
                Task { @MainActor in self.summaryProgress = value }
            }
            append(message)
            finish()
        }
    }

    /// Adds a question and answer asked somewhere else, like the ask box.
    func record(question: String, answer: ChatMessage) {
        append(ChatMessage(role: .user, text: question))
        append(answer)
    }

    func stop() {
        task?.cancel()
        finish()
    }

    func clear() async {
        stop()
        messages = []
        await Library.shared.engine.clearMessages(scope: scope.key)
    }

    private func finish() {
        task = nil
        isWorking = false
        partial = nil
        status = nil
        summaryProgress = nil
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        let scope = scope.key
        if let data = try? JSONEncoder().encode(message) {
            Task { await Library.shared.engine.saveMessage(data, scope: scope) }
        }
    }

    /// The last question and its checked answer, for follow-ups.
    private func lastExchange() -> (q: String, a: String)? {
        let earlier = messages.dropLast()
        guard let answer = earlier.last, answer.role == .assistant, answer.outcome == .answered,
              let question = earlier.dropLast().last, question.role == .user else { return nil }
        return (question.text, answer.text)
    }
}

/// Keeps one chat per scope while the app runs.
@MainActor
enum Chats {
    private static var all: [String: ChatModel] = [:]

    static func model(for scope: ChatScope) -> ChatModel {
        if let model = all[scope.key] { return model }
        let model = ChatModel(scope: scope)
        all[scope.key] = model
        return model
    }

    static func forgetAll() { all.removeAll() }
}
