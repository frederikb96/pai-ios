import PAIKit
import SwiftUI

/// One of the bottom row's three shortcuts — a link Freddy configures himself by long-pressing the
/// tile, since Todoist's own view/filter URLs are his to find and paste rather than something
/// this app can construct (a saved-filter URL in particular names an id only his account has).
/// Persisted locally, never synced: this is a per-device convenience, not app state PAI Cloud
/// needs to know about.
private struct QuickActionShortcut: Equatable {
    var name: String
    var urlString: String

    var isConfigured: Bool { !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var url: URL? { isConfigured ? URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
}

/// Where the hardware Action Button lands: five rows, reachable without the last being cut off —
/// the layout Freddy actually reaches for, not a uniform grid that happens to hold every tile at
/// one size. The row widths differ on purpose: one full-width tile, three two-up rows, and a
/// three-up row of shortcuts, each of which he configures himself.
///
/// The button is pressed without looking — walking, in a coat pocket, mid-sentence — so the whole
/// screen is one glance and one thumb. That is what sets the shape: large targets rather than a
/// list, each laid out so a tile's position is learnable and stays put. Nothing here loads, so
/// there is no state in which the grid is not yet tappable.
///
/// 🚨 Row height is divided out of the measured screen by `rowCount`, then held between a floor
/// and a ceiling. The floor keeps a target big enough to hit without looking on a small phone;
/// the ceiling keeps a large one from stretching every tile to fill space it does not need, which
/// reads as a screen of six enormous buttons rather than a glanceable grid.
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
    /// Computer (full-width), Home/Fast typed, Home/Fast call, notes, and a three-up shortcut row.
    private let rowCount: CGFloat = 5
    /// Big enough to hit without looking, on the smallest phone this runs on.
    private let minRowHeight: CGFloat = 88
    private let maxRowHeight: CGFloat = 104
    /// The Computer tile is full width, so it needs less height than a half-width tile to carry
    /// the same label — and it is the one tile whose position is never in doubt.
    private let computerHeightFactor: CGFloat = 0.8

    @AppStorage("quickActionShortcut1Name") private var shortcut1Name = ""
    @AppStorage("quickActionShortcut1URL") private var shortcut1URLString = ""
    @AppStorage("quickActionShortcut2Name") private var shortcut2Name = ""
    @AppStorage("quickActionShortcut2URL") private var shortcut2URLString = ""
    @AppStorage("quickActionShortcut3Name") private var shortcut3Name = ""
    @AppStorage("quickActionShortcut3URL") private var shortcut3URLString = ""
    @State private var editingShortcutSlot: Int?

    private var shortcut1: QuickActionShortcut {
        QuickActionShortcut(name: shortcut1Name, urlString: shortcut1URLString)
    }
    private var shortcut2: QuickActionShortcut {
        QuickActionShortcut(name: shortcut2Name, urlString: shortcut2URLString)
    }
    private var shortcut3: QuickActionShortcut {
        QuickActionShortcut(name: shortcut3Name, urlString: shortcut3URLString)
    }

    private func shortcutNameBinding(slot: Int) -> Binding<String> {
        switch slot {
        case 1: $shortcut1Name
        case 2: $shortcut2Name
        default: $shortcut3Name
        }
    }

    private func shortcutURLBinding(slot: Int) -> Binding<String> {
        switch slot {
        case 1: $shortcut1URLString
        case 2: $shortcut2URLString
        default: $shortcut3URLString
        }
    }

    var body: some View {
        // Measured rather than given a fixed tile height: the whole point is targets big enough
        // to hit without looking, and a grid that sizes itself to its content leaves part of the
        // screen empty on a large phone while overflowing a small one.
        //
        // 🚨 A `.frame(minHeight:maxHeight:)` proposes a size — it does not forcibly clip a child
        // that refuses to shrink smaller, so on a device where the five-way division comes out
        // below a tile's own minimum content height (icon + title + subtitle + padding), the grid
        // as a whole grows past what `GeometryReader` measured, which is exactly the "last row
        // cut off" failure this screen exists to fix. The `ScrollView` below is the backstop for
        // that case — never the primary mechanism — so a smaller phone than this was tuned
        // against scrolls a few points rather than hard-clipping the bottom row again.
        GeometryReader { proxy in
            ScrollView {
                grid(rowHeight: rowHeight(in: proxy.size.height))
                    .frame(minHeight: proxy.size.height, alignment: .top)
            }
        }
        .paiScreenBackground()
        .navigationTitle("Quick Actions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("quick-actions-screen")
        .sheet(item: $editingShortcutSlot.map { slot in EditingSlot(slot: slot) }) { editing in
            ShortcutEditSheet(
                name: shortcutNameBinding(slot: editing.slot),
                urlString: shortcutURLBinding(slot: editing.slot)
            )
        }
    }

    private func grid(rowHeight: CGFloat) -> some View {
        VStack(spacing: spacing) {
            computerTile(height: rowHeight * computerHeightFactor)
            HStack(spacing: spacing) {
                tile(
                    title: "Home", subtitle: "Type", systemImage: "house.fill",
                    tint: PaiPalette.primary500, height: rowHeight, identifier: "quick-home"
                ) {
                    startSession(type: "home", call: false)
                }
                tile(
                    title: "Fast", subtitle: "Type", systemImage: "bolt.fill",
                    tint: PaiPalette.amber500, height: rowHeight, identifier: "quick-fast"
                ) {
                    startSession(type: "fast", call: false)
                }
            }
            HStack(spacing: spacing) {
                tile(
                    title: "Home", subtitle: "Call", systemImage: "phone.fill",
                    tint: PaiPalette.primary500, height: rowHeight, identifier: "quick-home-call"
                ) {
                    startSession(type: "home", call: true)
                }
                tile(
                    title: "Fast", subtitle: "Call", systemImage: "phone.badge.waveform.fill",
                    tint: PaiPalette.amber500, height: rowHeight, identifier: "quick-fast-call"
                ) {
                    startSession(type: "fast", call: true)
                }
            }
            HStack(spacing: spacing) {
                tile(
                    title: "Find note", subtitle: "Filter", systemImage: "magnifyingglass",
                    tint: PaiPalette.Semantic.textSecondary, height: rowHeight, identifier: "quick-find-note"
                ) {
                    NotesFilterFocus.shared.arm()
                    environment.router.replace(with: [.notes])
                }
                tile(
                    title: "New note", subtitle: "Write", systemImage: "square.and.pencil",
                    tint: PaiPalette.Semantic.textSecondary, height: rowHeight, identifier: "quick-new-note"
                ) {
                    Task { await createNote() }
                }
            }
            HStack(spacing: spacing) {
                shortcutTile(shortcut1, slot: 1, height: rowHeight, identifier: "quick-shortcut-1")
                shortcutTile(shortcut2, slot: 2, height: rowHeight, identifier: "quick-shortcut-2")
                shortcutTile(shortcut3, slot: 3, height: rowHeight, identifier: "quick-shortcut-3")
            }
        }
        .padding(padding)
    }

    /// The always-reachable voice agent — full-width, since it is the one tile meant to be found
    /// without even glancing at the grid's own two-column rhythm.
    /// Divided out of the measured height, then clamped. `GeometryReader` is what makes the grid
    /// fit a screen it was never tuned against; the clamp is what stops it stretching to fill one.
    private func rowHeight(in availableHeight: CGFloat) -> CGFloat {
        let divided = (availableHeight - padding * 2 - spacing * (rowCount - 1)) / rowCount
        return min(maxRowHeight, max(minRowHeight, divided))
    }

    private func computerTile(height: CGFloat) -> some View {
        Button {
            ComputerCallEntry.open(environment)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(PaiPalette.primary500)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Computer")
                        .font(PaiTypography.panelTitle.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text("Talk to the switchboard")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("quick-computer")
        .accessibilityLabel("Computer")
    }

    private func tile(
        title: String, subtitle: String, systemImage: String, tint: Color, height: CGFloat,
        identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Text(title)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            // Claims the whole tile. A plain `Button` is hit-tested against what it draws, so a
            // label with a `Spacer` in it answers a tap on the text and ignores the empty space
            // around it — which on a control this size is most of it.
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    /// A configurable shortcut — task-shaped icon per Freddy's own ask, long-press to set its
    /// name and link. An unconfigured slot's tap opens the same editor a long press would, so
    /// pasting the link in is the tile's own first affordance rather than something that does
    /// nothing until discovered.
    private func shortcutTile(_ shortcut: QuickActionShortcut, slot: Int, height: CGFloat, identifier: String)
        -> some View
    {
        Button {
            guard let url = shortcut.url else {
                editingShortcutSlot = slot
                return
            }
            UIApplication.shared.open(url)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                Spacer(minLength: 0)
                Text(shortcut.isConfigured ? shortcut.name.isEmpty ? "Shortcut" : shortcut.name : "Set up")
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                Text(shortcut.isConfigured ? "Todoist" : "Tap to add")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(shortcut.isConfigured ? shortcut.name : "Configure shortcut")
        // A `contextMenu` rather than `onLongPressGesture`: this tile IS a button, and a button's
        // own gesture recogniser wins that contest often enough that the long press reads as
        // broken. The context menu is the long press SwiftUI hands to a button on purpose, and it
        // shows what it offers rather than firing invisibly.
        .contextMenu {
            Button("Edit shortcut", systemImage: "pencil") { editingShortcutSlot = slot }
        }
    }

    /// Both session tiles: record the launch choice where `CreateSessionView` already looks for
    /// one, arm hands-free dictation if this was a call tile, and replace the path.
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

/// `.sheet(item:)` needs an `Identifiable` — a bare `Int?` slot number wrapped just enough to be
/// one, so a *different* slot opening while the sheet is already up gets a fresh identity.
private struct EditingSlot: Identifiable, Equatable {
    let slot: Int
    var id: Int { slot }
}

extension Binding<Int?> {
    /// Maps an optional binding through a transform, for `.sheet(item:)` over a plain `Int?`
    /// state that is not itself `Identifiable`.
    fileprivate func map<T>(_ transform: @escaping (Int) -> T) -> Binding<T?> {
        Binding<T?>(
            get: { self.wrappedValue.map(transform) },
            set: { newValue in if newValue == nil { self.wrappedValue = nil } }
        )
    }
}

/// The name + link editor a long press (or an unconfigured tap) opens.
private struct ShortcutEditSheet: View {
    @Binding var name: String
    @Binding var urlString: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("shortcut-edit-name")
                    TextField("Link", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("shortcut-edit-url")
                } footer: {
                    Text("Paste a Todoist view or saved-filter link. Opens in the Todoist app if it's installed.")
                }
            }
            .navigationTitle("Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
