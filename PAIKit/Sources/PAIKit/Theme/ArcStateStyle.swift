// Guarded so the rest of the package builds on Linux, where CI is free — same reasoning as
// `PaiPalette.swift`, SwiftUI is the Apple-only dependency here too.
#if canImport(SwiftUI)

    import SwiftUI

    /// One definition per `ArcBadgeState`, shared by the flow card's icon tile, the badge pill
    /// and the legend — so a colour or icon is never chosen twice and cannot drift between the
    /// three surfaces. Mirrors `arcStateStyle.ts`'s `ARC_STATE_META`, adapted to this app's
    /// single-swatch-per-token palette (no light/dark pair per token — see `PaiPalette`'s own
    /// doc comment on why one fixed swatch already reads correctly in both appearances).
    public struct ArcStateMeta: Sendable {
        public let label: String
        public let systemImage: String
        /// The flow card's coloured icon tile — a solid fill with a white glyph, since the
        /// brief asks for colour alone to carry the state at a glance, with no need to open the
        /// card. Also the badge pill's icon/text colour and the legend swatch's fill, so all
        /// three read as the same state at a glance.
        public let tileColor: Color
        public let cardBorderColor: Color
        public let cardBackgroundColor: Color
    }

    public enum ArcStateStyle {
        public static func meta(for state: ArcBadgeState) -> ArcStateMeta {
            switch state {
            case .notSpawned:
                return ArcStateMeta(
                    label: "not spawned", systemImage: "circle.dashed", tileColor: PaiPalette.surface400,
                    cardBorderColor: PaiPalette.Semantic.borderDefault,
                    cardBackgroundColor: PaiPalette.Semantic.raisedSurface)
            case .working:
                return ArcStateMeta(
                    label: "working", systemImage: "gearshape.2.fill", tileColor: PaiPalette.blue500,
                    cardBorderColor: PaiPalette.blue500.opacity(0.45),
                    cardBackgroundColor: PaiPalette.blue500.opacity(0.08))
            case .returned:
                return ArcStateMeta(
                    label: "returned", systemImage: "tray.and.arrow.down.fill", tileColor: PaiPalette.amber500,
                    cardBorderColor: PaiPalette.amber500.opacity(0.45),
                    cardBackgroundColor: PaiPalette.amber500.opacity(0.08))
            case .accepted:
                return ArcStateMeta(
                    label: "accepted", systemImage: "checkmark.circle.fill", tileColor: PaiPalette.green500,
                    cardBorderColor: PaiPalette.green500.opacity(0.45),
                    cardBackgroundColor: PaiPalette.green500.opacity(0.08))
            case .cancelled:
                return ArcStateMeta(
                    label: "cancelled", systemImage: "xmark.circle", tileColor: PaiPalette.surface400,
                    cardBorderColor: PaiPalette.Semantic.borderDefault,
                    cardBackgroundColor: PaiPalette.Semantic.panelBackground)
            }
        }

        /// Fixed left-to-right order for anywhere every state is listed at once — the legend,
        /// and any future summary. Not `ArcBadgeState.allCases` (the type has none, being an
        /// enum with an associated derivation rather than a plain case list) — spelled out so
        /// the order is a deliberate choice, matching `arcStateStyle.ts`'s own `ARC_BADGE_STATES`.
        public static let allStates: [ArcBadgeState] = [.notSpawned, .working, .returned, .accepted, .cancelled]
    }

#endif
