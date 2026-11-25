import Foundation
import Observation

/// The user's settings, saved in UserDefaults.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var askShortcut: Shortcut {
        didSet { defaults.set(try? JSONEncoder().encode(askShortcut), forKey: "shortcut.ask") }
    }
    var watchedFolders: [String] { didSet { defaults.set(watchedFolders, forKey: "watchedFolders") } }
    var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: "pauseOnBattery") } }
    /// "Automatic" answers in the language of the question.
    var answerLanguage: String { didSet { defaults.set(answerLanguage, forKey: "answerLanguage") } }
    var welcomeDone: Bool { didSet { defaults.set(welcomeDone, forKey: "welcomeDone") } }

    static let automatic = "Automatic"
    static let languages = [
        automatic, "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Swedish",
        "Danish", "Norwegian", "Polish", "Turkish", "Vietnamese", "Japanese", "Korean", "Chinese",
    ]

    /// The language to ask the model for, or nil for the question's own.
    var languageForAnswers: String? { answerLanguage == Self.automatic ? nil : answerLanguage }

    private init() {
        if let data = defaults.data(forKey: "shortcut.ask"), let saved = try? JSONDecoder().decode(Shortcut.self, from: data) {
            askShortcut = saved
        } else {
            askShortcut = .ask
        }
        watchedFolders = defaults.stringArray(forKey: "watchedFolders") ?? []
        pauseOnBattery = defaults.object(forKey: "pauseOnBattery") as? Bool ?? true
        answerLanguage = defaults.string(forKey: "answerLanguage") ?? Self.automatic
        welcomeDone = defaults.bool(forKey: "welcomeDone")
    }
}
