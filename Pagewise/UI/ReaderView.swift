import PDFKit
import SwiftUI

/// Shows a PDF, and jumps to a page with a sentence highlighted.
struct ReaderView: NSViewRepresentable {
    let url: URL
    let doc: Int64
    let focus: ReaderFocus?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            context.coordinator.token = nil
            view.document = PDFDocument(url: url)
        }
        guard let focus, focus.token != context.coordinator.token, let document = view.document else { return }
        context.coordinator.token = focus.token
        guard let page = document.page(at: focus.page) else { return }
        view.highlightedSelections = nil
        if let quote = focus.quote, let selection = ReaderFinder.find(quote, on: page, in: document) {
            selection.color = NSColor.systemYellow.withAlphaComponent(0.55)
            view.highlightedSelections = [selection]
            // Scroll so the sentence sits a little below the top, not under it.
            let bounds = selection.bounds(for: page)
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: min(page.bounds(for: .mediaBox).maxY, bounds.maxY + 90)))
            view.go(to: destination)
            DispatchQueue.main.async { view.go(to: destination) }
        } else {
            view.go(to: page)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var url: URL?
        var token: UUID?
    }
}
