import Sparkle
import SwiftUI

@main
struct PagewiseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Pagewise", id: "library") {
            LibraryView()
                .task { await Library.shared.load() }
        }
        .defaultSize(width: 1240, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { appDelegate.updater.checkForUpdates(nil) }
                    .disabled(!AppDelegate.isReleaseBuild)
            }
            CommandGroup(after: .newItem) {
                Button("Ask from Anywhere…") { appDelegate.askBox.toggle() }
            }
            CommandGroup(after: .help) {
                Button("Show Debug Log") { appDelegate.showDebugLog() }
                #if DEBUG
                Button("Show Welcome Again") { appDelegate.showWelcome() }
                #endif
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }
}

/// The menu bar icon. It also hands AppDelegate a way to open the
/// window, because SwiftUI only gives that to views.
private struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "doc.text.magnifyingglass")
            .onAppear {
                AppDelegate.shared?.openLibrary = {
                    openWindow(id: "library")
                    NSApp.activate()
                }
            }
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let library = Library.shared

    var body: some View {
        Button("Ask… (\(Prefs.shared.askShortcut.display))") { AppDelegate.shared?.askBox.toggle() }
        Button("Open Pagewise") {
            openWindow(id: "library")
            NSApp.activate()
        }
        if library.isIndexing {
            Divider()
            Text("Indexing…")
        }
        Divider()
        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        Button("Quit Pagewise") { NSApp.terminate(nil) }
    }
}
