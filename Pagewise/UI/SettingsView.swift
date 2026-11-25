import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable private var prefs = Prefs.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmDelete = false
    @State private var shortcutTaken = false
    private let library = Library.shared

    var body: some View {
        Form {
            Section("Ask from anywhere") {
                LabeledContent("Open the ask box") {
                    HStack {
                        if shortcutTaken {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help("Another app uses this shortcut. Pick another.")
                        }
                        ShortcutRecorder(shortcut: $prefs.askShortcut, pause: { AppDelegate.shared?.pauseShortcuts() }) {
                            AppDelegate.shared?.registerShortcuts()
                            shortcutTaken = AppDelegate.shared?.shortcutTaken ?? false
                        }
                    }
                }
                Text("With a PDF open in Preview, the box asks about that PDF. Otherwise it asks your whole library.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Watched folders") {
                if prefs.watchedFolders.isEmpty {
                    Text("None. PDFs in watched folders are added and indexed by themselves.")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.watchedFolders, id: \.self) { folder in
                    HStack {
                        Image(systemName: "folder")
                        Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Stop Watching", role: .destructive) {
                            prefs.watchedFolders.removeAll { $0 == folder }
                            FolderWatcher.shared.restart()
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Button("Add Folder…", action: addFolder)
                    Spacer()
                    ForEach(quickFolders, id: \.self) { folder in
                        Button("Watch \((folder as NSString).lastPathComponent)") { watch(folder) }
                            .controlSize(.small)
                    }
                }
                Toggle("Pause indexing on battery", isOn: $prefs.pauseOnBattery)
            }

            Section("Answers") {
                Picker("Answer in", selection: $prefs.answerLanguage) {
                    ForEach(Prefs.languages, id: \.self) { language in
                        Text(language == Prefs.automatic ? "The language of the question" : language).tag(language)
                    }
                }
                if let message = Asker.unavailableMessage {
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Apple Intelligence is ready. It runs on this Mac.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("Apple's model reads about \(Asker.contextSize / 1000) thousand tokens at once, so Pagewise sends it only the pieces that match each question.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("General") {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { setLaunchAtLogin(launchAtLogin) }
                if AppDelegate.isReleaseBuild, let updater = AppDelegate.shared?.updater.updater {
                    Toggle("Check for updates by itself", isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }))
                }
            }

            Section("Privacy") {
                Text("Pagewise reads your PDFs and answers questions on this Mac, with Apple's own tools. It has no account and no tracking. It goes online only to check for updates. It never changes your PDFs.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Show Data Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Engine.folder])
                    }
                    Button("Delete Index and Chats…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .onAppear { shortcutTaken = AppDelegate.shared?.shortcutTaken ?? false }
        .confirmationDialog("Delete the index and all chats?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    Chats.forgetAll()
                    await library.deleteEverything()
                    prefs.watchedFolders = []
                    FolderWatcher.shared.restart()
                }
            }
        } message: {
            Text("Your PDFs stay where they are. Pagewise forgets them, their index and every chat. You cannot undo this.")
        }
    }

    private var quickFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Downloads", "Documents"].map { home.appending(path: $0).path }
            .filter { !prefs.watchedFolders.contains($0) }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Pick folders to watch for PDFs."
        if panel.runModal() == .OK {
            for url in panel.urls { watch(url.path) }
        }
    }

    private func watch(_ folder: String) {
        guard !prefs.watchedFolders.contains(folder) else { return }
        prefs.watchedFolders.append(folder)
        FolderWatcher.shared.restart()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.shared.add("Open at login: \(error.localizedDescription)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// A button that records a new shortcut when clicked.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    var pause: () -> Void
    var resume: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : shortcut.display)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .frame(minWidth: 90)
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        warning = nil
        pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            guard let new = Shortcut(event: event) else {
                warning = "Use ⌘, ⌃ or ⌥ with a key."
                return nil
            }
            shortcut = new
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            resume()
        }
    }
}
