import Foundation
import FoundationModels

/// A quote that passed the check, with where it is.
struct Citation: Codable, Sendable, Equatable, Identifiable, Hashable {
    var id: String { "\(doc)-\(page)-\(quote.prefix(40))" }
    let doc: Int64
    let title: String
    /// Counts from 0. Shown to people as page + 1.
    let page: Int
    let quote: String
}

/// One message in a chat.
struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
    enum Role: String, Codable, Sendable { case user, assistant }
    enum Outcome: String, Codable, Sendable {
        /// The answer has checked quotes.
        case answered
        /// The PDFs do not seem to hold the answer.
        case notFound
        /// The model answered, but no quote passed the check.
        case unchecked
        /// A summary or other text that is not checked against quotes.
        case summary
        case failed
    }

    var id = UUID()
    let role: Role
    var text: String
    var outcome: Outcome = .answered
    var citations: [Citation] = []
    /// The model's answer when no quote passed, shown only if asked.
    var uncheckedText: String?
    /// "report.pdf: pages 4, 12" for each PDF searched.
    var searched: [String] = []
    var closest: [Citation] = []
}

/// What the model must fill in. Guided generation keeps the shape fixed,
/// so the quotes can be checked one by one.
@Generable
struct ModelAnswer {
    @Guide(description: "true only if the sources contain the answer")
    var found: Bool
    @Guide(description: "The answer in plain words, in two to five short sentences. If found is false, say what is missing.")
    var answer: String
    @Guide(description: "Up to three sentences copied word for word from the sources that support the answer", .maximumCount(3))
    var quotes: [ModelQuote]
}

@Generable
struct ModelQuote {
    @Guide(description: "The number of the source the sentence is from")
    var source: Int
    @Guide(description: "A sentence copied word for word from that source")
    var text: String
}

/// Progress while a question is answered.
enum AskUpdate: Sendable {
    case searching
    case writing(String)
    case done(ChatMessage)
}

/// Answers questions from the library with Apple's on-device model.
enum Asker {
    static let instructions = """
        You answer questions about the user's documents. Use only the numbered sources you are given. \
        Never use outside knowledge, and never guess. \
        If the sources do not answer the question, set found to false. \
        Every quote must be copied word for word from a source. \
        Write plainly and briefly.
        """

    /// nil when the model can be used. Otherwise a message for the user.
    static var unavailableMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Turn it on in System Settings to ask questions."
            case .deviceNotEligible:
                return "This Mac does not support Apple Intelligence, so Pagewise cannot answer questions."
            case .modelNotReady:
                return "Apple Intelligence is still getting ready. Try again in a few minutes."
            @unknown default:
                return "Apple Intelligence is not available right now."
            }
        }
    }

    /// How many tokens the model can hold. 4,096 on macOS 26; more on
    /// newer systems and Macs.
    static var contextSize: Int {
        if #available(macOS 26.4, *) { return SystemLanguageModel.default.contextSize }
        return 4096
    }

    static func tokens(_ text: String) async -> Int {
        if #available(macOS 26.4, *), let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
            return count
        }
        return text.count / 3 + 1
    }

    /// Answers a question. `titles` names each PDF by id.
    static func ask(
        _ question: String, docs: [Int64]?, titles: [Int64: String], previous: (q: String, a: String)?,
        language: String?, engine: Engine
    ) -> AsyncStream<AskUpdate> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.searching)
                let message = await answer(
                    question, docs: docs, titles: titles, previous: previous, language: language, engine: engine
                ) { partial in continuation.yield(.writing(partial)) }
                continuation.yield(.done(message))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func answer(
        _ question: String, docs: [Int64]?, titles: [Int64: String], previous: (q: String, a: String)?,
        language: String?, engine: Engine, partial: @Sendable (String) -> Void
    ) async -> ChatMessage {
        if let message = unavailableMessage {
            return ChatMessage(role: .assistant, text: message, outcome: .failed)
        }
        // A follow-up like "and on page 5?" searches better with the last question in it.
        let searchText = previous.map { "\($0.q) \(question)" } ?? question
        let hits = await engine.search(searchText, docs: docs)
        guard !hits.isEmpty else {
            return ChatMessage(role: .assistant, text: "I couldn't find anything about that in these PDFs.", outcome: .notFound)
        }

        // Fill the model's space with as many pieces as fit.
        var header = ""
        if let previous {
            header = "Earlier question: \(previous.q)\nEarlier answer: \(previous.a.prefix(400))\n\n"
        }
        let languageLine = language.map { "Answer in \($0)." } ?? "Answer in the language of the question."
        let instructionCost = await tokens(instructions)
        let questionCost = await tokens(header + question + languageLine)
        let fixed = instructionCost + questionCost + 350  // the answer's shape
        let budget = max(600, contextSize - fixed - 900)  // room for the answer
        var costs: [Int64: Int] = [:]
        for hit in hits { costs[hit.id] = await tokens(hit.text) + 14 }
        let chosen = Ranking.pack(hits, budget: budget) { costs[$0.id] ?? 200 }

        var sources = ""
        for (number, hit) in chosen.enumerated() {
            sources += "Source \(number + 1) (\(titles[hit.doc] ?? "PDF"), page \(hit.page + 1)):\n\(hit.text)\n\n"
        }
        let prompt = """
            \(header)Sources:

            \(sources)Question: \(question)

            \(languageLine)
            """

        let searched = searchedSummary(chosen, titles: titles)
        let closest = chosen.prefix(3).map {
            Citation(doc: $0.doc, title: titles[$0.doc] ?? "PDF", page: $0.page, quote: String($0.text.prefix(160)))
        }

        do {
            let session = LanguageModelSession(instructions: instructions)
            var final: ModelAnswer.PartiallyGenerated?
            let stream = session.streamResponse(to: prompt, generating: ModelAnswer.self, options: GenerationOptions(temperature: 0.2))
            for try await snapshot in stream {
                final = snapshot.content
                if let text = snapshot.content.answer { partial(text) }
            }
            guard let final, let text = final.answer, !text.isEmpty else {
                return ChatMessage(role: .assistant, text: "Apple's model gave no answer. Try asking another way.", outcome: .failed, searched: searched)
            }

            // The quote check.
            var citations: [Citation] = []
            for quote in final.quotes ?? [] {
                guard let quoteText = quote.text, !quoteText.isEmpty else { continue }
                let hint = quote.source.map { $0 - 1 }
                guard let index = QuoteCheck.find(quoteText, in: chosen.map(\.text), hint: hint) else { continue }
                let hit = chosen[index]
                let citation = Citation(doc: hit.doc, title: titles[hit.doc] ?? "PDF", page: hit.page, quote: quoteText)
                if !citations.contains(citation) { citations.append(citation) }
            }

            citations = relevant(citations, answer: text, question: question)

            if final.found == false {
                return ChatMessage(
                    role: .assistant, text: "I couldn't find that in \(scopeName(docs, titles: titles)).",
                    outcome: .notFound, searched: searched, closest: closest)
            }
            if citations.isEmpty {
                return ChatMessage(
                    role: .assistant,
                    text: "I couldn't check an answer against \(scopeName(docs, titles: titles)), so I won't show it as fact.",
                    outcome: .unchecked, uncheckedText: text, searched: searched, closest: closest)
            }
            return ChatMessage(role: .assistant, text: text, outcome: .answered, citations: citations, searched: searched)
        } catch let error as LanguageModelSession.GenerationError {
            return ChatMessage(role: .assistant, text: message(for: error), outcome: .failed, searched: searched)
        } catch is CancellationError {
            return ChatMessage(role: .assistant, text: "Stopped.", outcome: .failed)
        } catch {
            return ChatMessage(role: .assistant, text: "Something went wrong: \(error.localizedDescription)", outcome: .failed)
        }
    }

    // MARK: - Summaries

    /// Sums up a PDF: each part first, then the parts together. Reports
    /// progress from 0 to 1.
    static func summarize(
        doc: Int64, title: String, language: String?, engine: Engine, progress: @Sendable (Double) -> Void
    ) async -> ChatMessage {
        if let message = unavailableMessage {
            return ChatMessage(role: .assistant, text: message, outcome: .failed)
        }
        let pieces = await engine.allPieces(of: doc)
        guard !pieces.isEmpty else {
            return ChatMessage(role: .assistant, text: "There is no text in this PDF yet.", outcome: .failed)
        }
        let languageLine = language.map { " Write in \($0)." } ?? ""
        let budget = max(800, contextSize - 1200)

        // Group pieces into parts that fit, keeping page order. Skip the
        // overlap the splitter added by taking every piece once.
        var parts: [(pages: ClosedRange<Int>, text: String)] = []
        var current = ""
        var first = pieces[0].page
        var last = first
        var used = 0
        for piece in pieces {
            let cost = await tokens(piece.text)
            if used + cost > budget, !current.isEmpty {
                parts.append((first...last, current))
                current = ""
                used = 0
                first = piece.page
            }
            current += piece.text + "\n"
            used += cost
            last = piece.page
        }
        if !current.isEmpty { parts.append((first...last, current)) }

        do {
            var notes: [String] = []
            for (index, part) in parts.enumerated() {
                try Task.checkCancellation()
                let session = LanguageModelSession(instructions: "You sum up parts of a document. Keep names, numbers and dates.")
                let pages = part.pages.lowerBound == part.pages.upperBound
                    ? "page \(part.pages.lowerBound + 1)" : "pages \(part.pages.lowerBound + 1)–\(part.pages.upperBound + 1)"
                let response = try await session.respond(
                    to: "Sum up this part (\(pages)) in at most four short sentences.\(languageLine)\n\n\(part.text)",
                    options: GenerationOptions(temperature: 0.2))
                notes.append("\(pages.capitalized): \(response.content)")
                progress(Double(index + 1) / Double(parts.count + 1))
            }
            if notes.count == 1 {
                progress(1)
                let text = notes[0].replacing(#/^Pages? [0-9–]+:\s/#, with: "")
                return ChatMessage(role: .assistant, text: text, outcome: .summary)
            }
            // Join the notes; if they are too long, keep the start of each.
            var joined = notes.joined(separator: "\n")
            if await tokens(joined) > budget {
                let share = max(80, (budget * 3) / max(1, notes.count))
                joined = notes.map { String($0.prefix(share)) }.joined(separator: "\n")
            }
            let session = LanguageModelSession(instructions: "You write short, clear summaries.")
            let response = try await session.respond(
                to: "These are notes on each part of “\(title)”. Write a summary of the whole document in one short paragraph, then up to five bullet points with the key facts.\(languageLine)\n\n\(joined)",
                options: GenerationOptions(temperature: 0.2))
            progress(1)
            return ChatMessage(role: .assistant, text: response.content, outcome: .summary)
        } catch let error as LanguageModelSession.GenerationError {
            return ChatMessage(role: .assistant, text: message(for: error), outcome: .failed)
        } catch {
            return ChatMessage(role: .assistant, text: "The summary stopped: \(error.localizedDescription)", outcome: .failed)
        }
    }

    // MARK: - Helpers

    /// Keeps the quotes that support the answer. The small model sometimes
    /// adds true but unrelated sentences. The best-matching quote always stays.
    static func relevant(_ citations: [Citation], answer: String, question: String) -> [Citation] {
        // Drop a quote that is already part of a longer one.
        let words = citations.map { " " + QuoteCheck.normalizedWords($0.quote).joined(separator: " ") + " " }
        let citations = citations.enumerated().filter { index, citation in
            !citations.indices.contains { other in
                other != index && citations[other].doc == citation.doc && words[other].count > words[index].count
                    && words[other].contains(words[index])
            }
        }.map(\.element)
        guard citations.count > 1 else { return citations }
        let target = Set(QuoteCheck.normalizedWords(answer + " " + question).filter { $0.count >= 3 })
        let scored = citations.map { citation -> (Citation, Double) in
            let words = QuoteCheck.normalizedWords(citation.quote).filter { $0.count >= 3 }
            guard !words.isEmpty else { return (citation, 0) }
            return (citation, Double(words.filter(target.contains).count) / Double(words.count))
        }
        let best = scored.max { $0.1 < $1.1 }!.0
        return scored.filter { $0.0 == best || $0.1 >= 0.3 }.map(\.0)
    }

    static func searchedSummary(_ hits: [Hit], titles: [Int64: String]) -> [String] {
        var pagesByDoc: [Int64: Set<Int>] = [:]
        var order: [Int64] = []
        for hit in hits {
            if pagesByDoc[hit.doc] == nil { order.append(hit.doc) }
            pagesByDoc[hit.doc, default: []].insert(hit.page + 1)
        }
        return order.map { doc in
            let pages = pagesByDoc[doc]!.sorted()
            let list = pages.map(String.init).joined(separator: ", ")
            return "\(titles[doc] ?? "PDF"): page\(pages.count == 1 ? "" : "s") \(list)"
        }
    }

    private static func scopeName(_ docs: [Int64]?, titles: [Int64: String]) -> String {
        if let docs, docs.count == 1, let title = titles[docs[0]] { return "“\(title)”" }
        if let docs, docs.count > 1 { return "these \(docs.count) PDFs" }
        return "your PDFs"
    }

    static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .guardrailViolation, .refusal:
            "Apple's model would not answer this."
        case .exceededContextWindowSize:
            "That was too long for Apple's model. Try a shorter question."
        case .unsupportedLanguageOrLocale:
            "Apple's model does not support this language yet."
        case .assetsUnavailable:
            "Apple Intelligence is still getting ready. Try again in a few minutes."
        default:
            "Apple's model had a problem: \(error.localizedDescription)"
        }
    }
}
