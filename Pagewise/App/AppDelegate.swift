import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let askBox = AskBoxController()
    private let hotKeys = HotKeys()
    private var welcomeWindow: NSWindow?
    private var logWindow: NSWindow?
    private(set) var shortcutTaken = false
    #if DEBUG
    private var selfTest: SelfTest?
    #endif

    /// Opens the main window. Set by the menu bar icon once it appears.
    var openLibrary: (() -> Void)? {
        didSet { askBox.openLibrary = openLibrary }
    }

    /// Sparkle checks GitHub for new versions. Off in debug builds.
    let updater = SPUStandardUpdaterController(
        startingUpdater: AppDelegate.isReleaseBuild, updaterDelegate: nil, userDriverDelegate: nil)

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.shared.add("Pagewise \(version) launched from \(Bundle.main.bundlePath)")
        hotKeys.onPress = { [weak self] _ in self?.askBox.toggle() }
        registerShortcuts()
        FolderWatcher.shared.restart()
        Log.shared.add("Apple Intelligence: \(Asker.unavailableMessage ?? "ready, context \(Asker.contextSize) tokens")")
        #if DEBUG
        selfTest = SelfTest()
        #endif
        if !Prefs.shared.welcomeDone { showWelcome() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openLibrary?() }
        return true
    }

    /// PDFs dropped on the Dock icon or opened with Pagewise.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task {
            let ids = await Library.shared.add(urls)
            openLibrary?()
            if let first = ids.first {
                Library.shared.focus = ReaderFocus(doc: first, page: 0, quote: nil)
            }
        }
    }

    // MARK: - Shortcut

    func registerShortcuts() {
        shortcutTaken = !hotKeys.register([.ask: Prefs.shared.askShortcut]).isEmpty
        if shortcutTaken { Log.shared.add("The ask shortcut is used by another app. Pick another in Settings.") }
    }

    func pauseShortcuts() { hotKeys.unregisterAll() }

    // MARK: - Windows

    func showWelcome() {
        let view = WelcomeView { [weak self] in
            Prefs.shared.welcomeDone = true
            self?.welcomeWindow?.close()
        }
        if welcomeWindow == nil {
            welcomeWindow = Windows.make(title: "Welcome to Pagewise", size: NSSize(width: 540, height: 470), content: view)
        } else {
            welcomeWindow?.contentView = NSHostingView(rootView: view)
        }
        Windows.present(welcomeWindow!)
    }

    func showDebugLog() {
        if logWindow == nil {
            logWindow = Windows.make(
                title: "Pagewise Debug Log", size: NSSize(width: 720, height: 420), content: DebugLogView(log: Log.shared))
        }
        Windows.present(logWindow!)
    }
}
