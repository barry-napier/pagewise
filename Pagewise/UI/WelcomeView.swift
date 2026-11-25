import SwiftUI

/// First-run walk-through: what Pagewise does, Apple Intelligence, adding
/// PDFs, and the ask box.
struct WelcomeView: View {
    enum Step: Int { case hello, intelligence, pdfs, ready }

    @State private var step = Step.hello
    @State private var added = 0
    let finish: () -> Void
    private let prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 18) {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                ForEach(0..<4) { index in
                    Circle()
                        .fill(index == step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
                Spacer()
                if step != .hello {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .hello }
                }
                if step == .ready {
                    Button("Start", action: finish)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Continue") { step = Step(rawValue: step.rawValue + 1) ?? .ready }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 540, height: 470)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .hello:
            page("doc.text.magnifyingglass", "Ask your PDFs anything",
                 "Pagewise answers questions about your PDFs with Apple’s AI, right on this Mac. Nothing is uploaded.\n\nEvery answer shows the exact sentences it came from. Click one to see it highlighted on the page. If the answer isn’t in your PDFs, Pagewise says so.")
        case .intelligence:
            if let message = Asker.unavailableMessage {
                page("sparkles", "Answers need Apple Intelligence", message + "\n\nYou can still add PDFs now. They will be ready when Apple Intelligence is.")
            } else {
                page("sparkles", "Apple Intelligence is ready",
                     "Apple’s model runs on this Mac. It reads a few pages at a time, so Pagewise finds the right pages first, then asks it.")
            }
        case .pdfs:
            VStack(spacing: 16) {
                page("folder.badge.plus", "Add some PDFs",
                     "Drop PDFs into the Pagewise window, or let Pagewise watch a folder and add new PDFs by itself.")
                HStack {
                    Button("Watch Downloads") { watch("Downloads") }
                        .disabled(prefs.watchedFolders.contains(home("Downloads")))
                    Button("Watch Documents") { watch("Documents") }
                        .disabled(prefs.watchedFolders.contains(home("Documents")))
                }
                Text("macOS may ask if Pagewise can see that folder. You can change this later in Settings.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case .ready:
            VStack(spacing: 16) {
                page("keyboard", "Ask from anywhere",
                     "Press this in any app to open the ask box. With a PDF open in Preview, it asks about that PDF.")
                Text(prefs.askShortcut.display)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Text("The first time, macOS asks if Pagewise may talk to Preview. It only asks Preview which PDF is open.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func home(_ name: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: name).path
    }

    private func watch(_ name: String) {
        let folder = home(name)
        guard !prefs.watchedFolders.contains(folder) else { return }
        prefs.watchedFolders.append(folder)
        FolderWatcher.shared.restart()
    }

    private func page(_ symbol: String, _ title: String, _ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 46)).foregroundStyle(.tint)
            Text(title).font(.title2.weight(.semibold))
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
