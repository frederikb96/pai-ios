import PAIKit
import SwiftUI

/// Pick a session or a new one, then watch the files land on its draft.
struct ShareScreen: View {
    let providers: [NSItemProvider]
    let credentials: SharedCredentials?
    let close: () -> Void

    @State private var loaded: SharedItemLoader.Loaded?

    var body: some View {
        NavigationStack {
            Group {
                if let client {
                    if let loaded {
                        ShareFlowView(
                            store: ShareStore(
                                items: loaded.items, refusal: loaded.refusal, backend: client,
                                attemptMark: .extensionDefaults),
                            close: close)
                    } else {
                        ProgressView("Reading what you shared")
                    }
                } else {
                    ContentUnavailableView(
                        "Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Open PAI and sign in, then share again."))
                }
            }
            .navigationTitle("Attach to PAI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: close)
                }
            }
        }
        .task {
            guard client != nil, loaded == nil else { return }
            loaded = await SharedItemLoader.load(providers)
        }
    }

    private var client: PaiApiClient? {
        guard let credentials else { return nil }
        let token = credentials.token
        guard let factory = try? PaiRequestFactory(baseURL: credentials.backendURL, tokenProvider: { token })
        else { return nil }
        return PaiApiClient(requestFactory: factory)
    }
}

extension ShareAttemptMark {
    private static let key = "shareAttemptInProgress"

    static let extensionDefaults = ShareAttemptMark(
        isSet: { UserDefaults.standard.bool(forKey: key) },
        set: { UserDefaults.standard.set($0, forKey: key) })
}

private struct ShareFlowView: View {
    @State var store: ShareStore
    let close: () -> Void

    @State private var query = ""

    var body: some View {
        switch store.phase {
        case .choosing:
            chooser
        case .sending(let done, let total):
            ProgressView("Attaching \(done + 1) of \(total)", value: Double(done), total: Double(total))
                .padding()
        case .sent(let destination):
            ContentUnavailableView(
                "Attached", systemImage: "checkmark.circle", description: Text(sentMessage(destination))
            )
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                close()
            }
        case .failed(let destination, let message):
            ContentUnavailableView {
                Label("Not everything arrived", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await store.send(to: destination) } }
            }
        }
    }

    private var chooser: some View {
        List {
            if store.previousAttemptDied {
                Section {
                    Label(
                        "The last share stopped before it finished, so its files may be missing.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                }
            }
            Section {
                ForEach(store.items) { item in
                    Label(item.name, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                }
                if let refusal = store.refusal {
                    Text(refusal).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !store.items.isEmpty {
                Section {
                    Button {
                        Task { await store.send(to: .newSession) }
                    } label: {
                        Label("New session", systemImage: "plus.bubble")
                    }
                }
                Section("Sessions") {
                    if let error = store.sessionsError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(store.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search sessions")
        .task(id: query) {
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await store.loadSessions(query: query)
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        let title = SessionListFormat.displayTitle(for: session)
        return Button(title) {
            Task { await store.send(to: .session(id: session.id, title: title)) }
        }
        .lineLimit(2)
    }

    private func sentMessage(_ destination: ShareDestination) -> String {
        switch destination {
        case .newSession: return "Waiting in New Session. Open PAI to start it."
        case .session(_, let title): return "Waiting in the composer of \(title)."
        }
    }
}
