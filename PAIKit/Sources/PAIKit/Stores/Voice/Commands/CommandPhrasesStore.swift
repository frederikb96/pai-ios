import Foundation
import Observation

/// What `VoiceCommandsSection` shows and edits — the phrase-settings half of the offline command
/// channel, persisted through the same `SettingsKeyValueStore` every other client-side setting
/// uses, but as its own store rather than a property on `SettingsStore`, the way `SmtpSettingsStore`
/// already is (see that file's own doc comment for the same reasoning: Save/dirty tracking is
/// real state a flat property list shouldn't flatten away — here it's independent persistence
/// wiring instead, so this store can exist without `SettingsStore` needing a change to carry it).
@MainActor
@Observable
public final class CommandPhrasesStore {
    private enum Keys {
        static let phrases = "voiceCommandPhrases"
    }

    public private(set) var phraseSet: CommandPhraseSet
    private let storage: SettingsKeyValueStore

    public init(storage: SettingsKeyValueStore) {
        self.storage = storage
        let stored: [String: String]? = storage.value(forKey: Keys.phrases)
        guard let stored else {
            phraseSet = .defaults
            return
        }
        var phrases = CommandPhraseSet.defaults.phrases
        for (rawKind, phrase) in stored {
            guard let kind = CommandKind(rawValue: rawKind) else { continue }
            phrases[kind] = phrase
        }
        phraseSet = CommandPhraseSet(phrases: phrases)
    }

    /// An empty phrase resets that command to its default rather than leaving it blank — a blank
    /// phrase can never match anything, which would silently turn a command off with no
    /// indication in the UI that it did.
    public func setPhrase(_ phrase: String, for kind: CommandKind) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        phraseSet.phrases[kind] = trimmed.isEmpty ? CommandPhraseSet.defaults.phrases[kind] : trimmed
        persist()
    }

    public func resetToDefaults() {
        phraseSet = .defaults
        persist()
    }

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: phraseSet.phrases.map { ($0.key.rawValue, $0.value) })
        storage.setValue(raw, forKey: Keys.phrases)
    }
}
