import PAIKit
import SwiftUI

/// One agent browser session, live: the page drawn big enough to pinch and pan around in, a tap
/// clicks, a one-finger drag scrolls the page, a long press right-clicks, a text field and key
/// buttons type into whatever the page has focused, and Done / Couldn't do it end a handover.
/// Swift port of `LiveView.tsx`; the touch rules are `BrowserGestureInterpreter`'s.
struct BrowserLiveScreen: View {
    @Environment(AppEnvironment.self) private var environment

    let name: String

    @State private var store: BrowserViewStore?
    @State private var typed = ""
    @State private var address = ""
    @FocusState private var isTyping: Bool
    @FocusState private var isAddressing: Bool

    private static let keys: [(label: String, key: String)] = [
        ("Enter", "Enter"), ("Tab", "Tab"), ("Esc", "Escape"),
        ("↑", "ArrowUp"), ("↓", "ArrowDown"), ("←", "ArrowLeft"), ("→", "ArrowRight"),
        ("⌫", "Backspace"),
    ]

    private var me: MeStore? { environment.connection?.me }

    var body: some View {
        Group {
            if let capabilities = me?.capabilities, capabilities.isKnown, !capabilities.canOpenBrowser {
                ContentUnavailableView(
                    "Owner Only", systemImage: "lock",
                    description: Text("Browser sessions can only be opened by the account owner."))
            } else if let store {
                content(store)
            } else if let error = me?.loadError {
                VStack(spacing: 8) {
                    Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
                    Button("Retry") { Task { await me?.refresh() } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(store?.session?.displayTitle ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("browser-screen")
        // Identified by whether identity is known: the stream is never opened before the account
        // is known to be allowed to open it, since a guest's request would be refused.
        .task(id: me?.me != nil) { await begin() }
        .onDisappear { store?.stop() }
    }

    private func begin() async {
        guard let connection = environment.connection, connection.me.capabilities.canOpenBrowser else { return }
        let current =
            store
            ?? BrowserViewStore(name: name, api: connection.apiClient, requestFactory: connection.requestFactory)
        store = current
        current.start()
    }

    // MARK: Layout

    private func content(_ store: BrowserViewStore) -> some View {
        VStack(spacing: 0) {
            addressBar(store)
            if let handoff = store.session?.handoff { handoffBanner(handoff, store: store) }
            if case .finished(let message) = store.handback {
                Text(message)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            ZStack {
                BrowserSurface(store: store)
                overlay(store)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            inputPanel(store)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    store.send(.nav(.back))
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back")
                Button {
                    store.send(.nav(.forward))
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .accessibilityLabel("Forward")
                Button {
                    store.send(.nav(.reload))
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Reload")
            }
        }
    }

    /// Shows the page's address and opens whatever is typed over it on Return, like the web's bar.
    /// The page's own navigation refreshes it unless the field is being edited.
    private func addressBar(_ store: BrowserViewStore) -> some View {
        TextField("Address", text: $address)
            .textFieldStyle(.roundedBorder)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .focused($isAddressing)
            .onSubmit {
                store.goto(address)
                isAddressing = false
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .onAppear { address = store.session?.url ?? "" }
            .onChange(of: store.session?.url) { _, url in
                if !isAddressing { address = url ?? "" }
            }
            .accessibilityIdentifier("browser-address-field")
    }

    private func handoffBanner(_ handoff: BrowserHandoff, store: BrowserViewStore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(handoff.reason)
                .font(PaiTypography.body.font)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button("Done") { Task { await store.finish(.done) } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("browser-done")
                Button("Couldn't do it") { Task { await store.finish(.failed) } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("browser-failed")
            }
            .disabled(store.handback == .sending)
        }
        .padding(12)
        .background(PaiPalette.amber500.opacity(0.18))
        .accessibilityIdentifier("browser-handoff")
    }

    @ViewBuilder
    private func overlay(_ store: BrowserViewStore) -> some View {
        if case .ended(let reason) = store.status {
            statusCard("This session ended: \(reason)")
        } else if !store.hasFrame {
            statusCard(statusLabel(store.status))
        }
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Text(statusLabel(store.status))
                    .font(PaiTypography.caption.font)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                Spacer()
                zoomButton("plus.magnifyingglass", "Zoom in") { store.gestures.zoomIn() }
                zoomButton("minus.magnifyingglass", "Zoom out") { store.gestures.zoomOut() }
                zoomButton("arrow.up.left.and.arrow.down.right", "Fit page") { store.gestures.fitPage() }
            }
            .padding(8)
        }
    }

    private func statusCard(_ text: String) -> some View {
        Text(text)
            .font(PaiTypography.body.font)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.7))
            .allowsHitTesting(false)
    }

    private func zoomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(.white)
        }
        .accessibilityLabel(label)
    }

    private func statusLabel(_ status: BrowserViewStore.Status) -> String {
        switch status {
        case .connecting: "Connecting…"
        case .live: "Live"
        case .reconnecting: "Reconnecting…"
        case .ended: "Ended"
        }
    }

    // MARK: Typing

    private func inputPanel(_ store: BrowserViewStore) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("Type into the page", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .focused($isTyping)
                    .onSubmit { sendTyped(store, thenEnter: false) }
                    .accessibilityIdentifier("browser-text-field")
                Button("Send") { sendTyped(store, thenEnter: false) }
                    .buttonStyle(.bordered)
                Button {
                    sendTyped(store, thenEnter: true)
                } label: {
                    Image(systemName: "return")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Send and press Enter")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.keys, id: \.key) { entry in
                        Button(entry.label) { store.send(.key(entry.key)) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(8)
    }

    private func sendTyped(_ store: BrowserViewStore, thenEnter: Bool) {
        store.sendTyped(typed, thenEnter: thenEnter)
        typed = ""
        isTyping = true
    }
}
