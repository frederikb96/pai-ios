import Foundation
import Observation

/// What the offline wake-word engine listens for — persisted independently of `SettingsStore`,
/// the same shape `SmtpSettingsStore` already is (see that file's own doc comment for the same
/// reasoning: this is its own persistence wiring, not a property `SettingsStore` needs to carry).
///
/// The phrases themselves are fixed — baked into trained classifiers, never typed — so there is
/// nothing to edit there. What is a real Freddy-facing choice is *which* commands run through the
/// offline engine at all, versus falling back to transcript recognition while recording; that
/// choice is what this store keeps.
@MainActor
@Observable
public final class WakeWordSettingsStore {
    private enum Keys {
        static let offlineCommands = "wakeWordOfflineCommands"
    }

    public private(set) var config: WakeWordListeningConfig
    private let storage: SettingsKeyValueStore

    /// An unrecognised stored value (a command this build no longer knows, a corrupted write)
    /// degrades to the full chart rather than to "the offline engine listens for nothing" —
    /// silently disabling every command is a worse default than the one Freddy actually wants.
    public init(storage: SettingsKeyValueStore) {
        self.storage = storage
        guard let stored: [String] = storage.value(forKey: Keys.offlineCommands) else {
            config = .fullChart
            return
        }
        let commands = Set(stored.compactMap(CommandKind.init(rawValue:)))
        config = commands.isEmpty ? .fullChart : WakeWordListeningConfig(offlineCommands: commands)
    }

    public func setOfflineCommands(_ commands: Set<CommandKind>) {
        config = commands.isEmpty ? .fullChart : WakeWordListeningConfig(offlineCommands: commands)
        persist()
    }

    /// Freddy's own documented fallback (his command chart's own note): only `start` runs
    /// offline, everything else falls back to transcript recognition while recording.
    public func useStartOnlyFallback() {
        setOfflineCommands(WakeWordListeningConfig.startOnlyFallback.offlineCommands)
    }

    public func useFullChart() {
        setOfflineCommands(WakeWordListeningConfig.fullChart.offlineCommands)
    }

    private func persist() {
        storage.setValue(config.offlineCommands.map(\.rawValue), forKey: Keys.offlineCommands)
    }
}
