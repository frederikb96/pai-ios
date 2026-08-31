// Guarded so the rest of the package builds on Linux, where CI is free — same reasoning as
// `PaiPalette.swift`, SwiftUI is the Apple-only dependency here too.
#if canImport(SwiftUI)

    import SwiftUI

    /// The page ground every screen sits on.
    ///
    /// The design assumes three depth steps — page, then panel, then raised card — and reads
    /// wrong when it has only two. `PaiPalette.Semantic.screenBackground` is the first of those
    /// steps; a screen that does not set it falls through to the system background, which in dark
    /// mode is pure black rather than the near-black slate the other two steps were chosen
    /// against. The step from black to card grey is far harsher than the design intends, and the
    /// gaps between cards read as holes rather than as air.
    ///
    /// So: every full-screen container reaches for one of these, and none of them paints a page
    /// ground by hand.
    extension View {

        /// The page ground for an ordinary screen. Extends under the safe areas so a scroll view
        /// bouncing past its content, and the space behind a translucent navigation or tab bar,
        /// both stay on the page colour.
        public func paiScreenBackground() -> some View {
            background(PaiPalette.Semantic.screenBackground, ignoresSafeAreaEdges: .all)
        }

        /// The page ground for a `List` or `Form`.
        ///
        /// Those two paint the system grouped background themselves, whose greys are *warm*,
        /// beside this app's cool slate everywhere else. Mixing the two families is the one wrong
        /// answer, and it is why a settings screen built from stock rows looks like it belongs to
        /// a different app. Hiding the system ground and painting the app's own keeps one family.
        public func paiListBackground() -> some View {
            scrollContentBackground(.hidden)
                .background(PaiPalette.Semantic.screenBackground, ignoresSafeAreaEdges: .all)
        }

        /// The page ground for the notes section.
        ///
        /// Its own neutral greys rather than the app's blue-tinted slate, because the writing
        /// surface is the thing the section is *about* and everything around it reads as a frame
        /// for it. Crossing from the index into a note, or from the editor into the preview,
        /// should not look like crossing into a different app.
        public func paiNotesBackground() -> some View {
            background(PaiPalette.Notes.background, ignoresSafeAreaEdges: .all)
        }

        /// ``paiNotesBackground()`` for a `List` or `Form`, which paint a ground of their own.
        public func paiNotesListBackground() -> some View {
            scrollContentBackground(.hidden)
                .background(PaiPalette.Notes.background, ignoresSafeAreaEdges: .all)
        }
    }

#endif
