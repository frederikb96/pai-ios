import Combine
import PAIKit
import SwiftUI

/// The spots on long screens that the fixture screenshot lane scrolls to, named by
/// `-PaiFixtureScrollTo <name>`. A screenshot shows only the top of a form, so a section lower
/// down is photographed only if the launch can bring it into view.
enum FixtureScrollAnchor: String {
    case notesCache
    case notSaved
    case taskNotifyPush
}

extension View {
    /// Scrolls the enclosed list to the row carrying `.id(FixtureScrollAnchor.<name>.rawValue)`
    /// that `-PaiFixtureScrollTo` names. Does nothing in a Release build or without the flag.
    func fixtureScrollsToAnchor() -> some View {
        #if DEBUG
            modifier(FixtureScrollModifier())
        #else
            self
        #endif
    }
}

#if DEBUG

    /// Repeats the scroll for a few seconds because the target may not exist at the first
    /// attempt: a screen that loads its content before drawing it has nothing to scroll to yet.
    private struct FixtureScrollModifier: ViewModifier {
        @State private var remaining = 8
        @State private var ticks = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

        func body(content: Content) -> some View {
            ScrollViewReader { proxy in
                content.onReceive(ticks) { _ in
                    guard remaining > 0, let name = PaiFixtureLaunch.requestedScrollAnchor() else { return }
                    remaining -= 1
                    proxy.scrollTo(name, anchor: .top)
                }
            }
        }
    }

#endif
