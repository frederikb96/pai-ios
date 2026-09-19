import PAIKit
import SwiftUI

/// Where the hardware Action Button lands: six large targets, two across, no scrolling and no
/// reading.
///
/// The button is pressed without looking — walking, in a coat pocket, mid-sentence — so the whole
/// screen is one glance and one thumb. That is what sets the shape: six tiles rather than a list,
/// each big enough to hit blind, laid out so a tile's position is learnable and stays put. Nothing
/// here loads, so there is no state in which the grid is not yet tappable.
///
/// Every tile ends in the same two places the app already had — the new-session screen or the note
/// index — and differs only in what it arms on the way. None of them owns behaviour of its own.
struct QuickActionsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(DraftStore.self) private var drafts
    @Environment(ToastCenter.self) private var toasts

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 16
    private let rows: CGFloat = 3

    var body: some View {
        // Measured rather than given a fixed tile height: the whole point is targets big enough
        // to hit without looking, and a grid that sizes itself to its content leaves a third of
        // the screen empty on a large phone while overflowing a small one.
        GeometryReader { proxy in
            grid(tileHeight: max(96, (proxy.size.height - padding * 2 - spacing * (rows - 1)) / rows))
        }
        .paiScreenBackground()
        .navigationTitle("Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quick-actions-screen")
    }

    private func grid(tileHeight: CGFloat) -> some View {
        LazyVGrid(columns: columns, spacing: spacing) {
            tile(
                title: "Home", subtitle: "Type", systemImage: "house.fill",
                tint: PaiPalette.primary500, height: tileHeight, identifier: "quick-home"
            ) {
                startSession(type: "home", call: false)
            }
            tile(
                title: "Fast", subtitle: "Type", systemImage: "bolt.fill",
                tint: PaiPalette.amber500, height: tileHeight, identifier: "quick-fast"
            ) {
                startSession(type: "fast", call: false)
            }
            tile(
                title: "Home", subtitle: "Call", systemImage: "phone.fill",
                tint: PaiPalette.primary500, height: tileHeight, identifier: "quick-home-call"
            ) {
                startSession(type: "home", call: true)
            }
            tile(
                title: "Fast", subtitle: "Call", systemImage: "phone.badge.waveform.fill",
                tint: PaiPalette.amber500, height: tileHeight, identifier: "quick-fast-call"
            ) {
                startSession(type: "fast", call: true)
            }
            tile(
                title: "Find note", subtitle: "Filter", systemImage: "magnifyingglass",
                tint: PaiPalette.Semantic.textSecondary, height: tileHeight, identifier: "quick-find-note"
            ) {
                NotesFilterFocus.shared.arm()
                environment.router.replace(with: [.notes])
            }
            tile(
                title: "New note", subtitle: "Write", systemImage: "square.and.pencil",
                tint: PaiPalette.Semantic.textSecondary, height: tileHeight, identifier: "quick-new-note"
            ) {
                Task { await createNote() }
            }
        }
        .padding(padding)
    }

    private func tile(
        title: String, subtitle: String, systemImage: String, tint: Color, height: CGFloat,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(title)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text(subtitle)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .padding(16)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            // Claims the whole tile. A plain `Button` is hit-tested against what it draws, so a
            // label with a `Spacer` in it answers a tap on the text and ignores the empty space
            // around it — which on a control this size is most of it.
            .contentShape(RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    /// Both session tiles: record the launch choice where `CreateSessionView` already looks for
    /// one, arm the call if this was a call tile, and replace the path.
    ///
    /// The draft is written locally and pushed to the server without being waited on. A local
    /// write is what the screen about to appear actually reads, and holding the navigation for a
    /// round trip would make a button pressed without looking feel like it did nothing.
    private func startSession(type: String, call: Bool) {
        // `selectWorkingDir(nil)` first: a directory chosen on a previous visit is what makes a
        // session custom, and it outranks the type, so leaving one in place would launch the
        // wrong thing while the screen showed the right pill.
        drafts.selectWorkingDir(nil)
        drafts.selectSessionType(type)
        if call {
            CallModeLaunchRequest.shared.arm()
        } else {
            CallModeLaunchRequest.shared.cancel()
        }
        environment.router.replace(with: [.createSession])
    }

    private func createNote() async {
        guard let created = await notes.createNote(name: NoteNaming.untitled) else {
            toasts.show(notes.loadError ?? "Could not create the note")
            return
        }
        NoteCreationFocus.shared.markCreated(id: created.id)
        environment.router.replace(with: [.notes, .note(id: created.id)])
    }
}
