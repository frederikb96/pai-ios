import XCTest
@testable import PAIKit

/// Neither the class nor any test method here is `@MainActor`, even though `CommandPhrasesStore`
/// correctly is — a Linux-only XCTest discovery crash fires when a *discovered test method*
/// carries that isolation (see `SettingsSmtpSettingsStoreTests`, the same pattern). Every store
/// access below is `await`ed instead.
final class CommandPhrasesStoreTests: XCTestCase {
    func testAFreshStoreStartsWithTheDefaultPhrases() async {
        let store = await CommandPhrasesStore(storage: SettingsInMemoryKeyValueStore())
        let phraseSet = await store.phraseSet
        XCTAssertEqual(phraseSet, .defaults)
    }

    func testSetPhrasePersistsAcrossANewStoreOverTheSameStorage() async {
        let storage = SettingsInMemoryKeyValueStore()
        let first = await CommandPhrasesStore(storage: storage)
        await first.setPhrase("Jarvis go", for: .start)

        let second = await CommandPhrasesStore(storage: storage)
        let phraseSet = await second.phraseSet
        XCTAssertEqual(phraseSet.phrases[.start], "Jarvis go")
        // Every other command falls back to its own default rather than being wiped by the
        // partial write — a fresh store reads one changed key alongside untouched defaults.
        XCTAssertEqual(phraseSet.phrases[.stop], CommandPhraseSet.defaults.phrases[.stop])
    }

    func testAnEmptyPhraseResetsThatCommandToItsDefaultRatherThanGoingBlank() async {
        let store = await CommandPhrasesStore(storage: SettingsInMemoryKeyValueStore())
        await store.setPhrase("Jarvis go", for: .start)
        await store.setPhrase("   ", for: .start)
        let phraseSet = await store.phraseSet
        XCTAssertEqual(phraseSet.phrases[.start], CommandPhraseSet.defaults.phrases[.start])
    }

    func testResetToDefaultsDiscardsEveryOverride() async {
        let storage = SettingsInMemoryKeyValueStore()
        let store = await CommandPhrasesStore(storage: storage)
        await store.setPhrase("Jarvis go", for: .start)
        await store.setPhrase("Jarvis silence", for: .mute)

        await store.resetToDefaults()
        let phraseSet = await store.phraseSet
        XCTAssertEqual(phraseSet, .defaults)

        // And the reset itself persists — a new store over the same storage must not resurrect
        // the overrides.
        let reloaded = await CommandPhrasesStore(storage: storage)
        let reloadedSet = await reloaded.phraseSet
        XCTAssertEqual(reloadedSet, .defaults)
    }

    func testAnUnrecognizedStoredKeyIsIgnoredRatherThanCrashingOrPoisoningTheRest() async {
        let storage = SettingsInMemoryKeyValueStore()
        storage.setValue(["not-a-real-command": "whatever"], forKey: "voiceCommandPhrases")
        let store = await CommandPhrasesStore(storage: storage)
        let phraseSet = await store.phraseSet
        XCTAssertEqual(phraseSet, .defaults)
    }
}
