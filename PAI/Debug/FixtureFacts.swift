import SwiftUI

extension View {
    /// Reports what this view shows to the debug bridge's `/fixture` answer, so a screenshot run
    /// can check the content it asked for and not only the route: a screen can render, pass every
    /// size check and still be the wrong composer. Does nothing in a Release build.
    func fixtureFact(_ key: String, _ value: String) -> some View {
        #if DEBUG
            task(id: value) { FixtureFacts.shared.record(key, value) }
        #else
            self
        #endif
    }
}

#if DEBUG

    /// What the screens on display have reported through ``SwiftUI/View/fixtureFact(_:_:)``.
    final class FixtureFacts: @unchecked Sendable {
        static let shared = FixtureFacts()

        private let lock = NSLock()
        private var facts: [String: String] = [:]

        func record(_ key: String, _ value: String) {
            lock.lock()
            facts[key] = value
            lock.unlock()
        }

        var snapshot: [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return facts
        }
    }

#endif
