import PAIKit
import SwiftUI

/// Which directories on which machines are synced as notes. The one place a container that
/// stopped itself becomes actionable rather than merely visible: the mass-delete breaker and a
/// missing-path pause show their reason and the two ways out, inline on the row that is paused.
struct NoteContainersScreen: View {
    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var busyId: String?
    @State private var showAdd = false

    var body: some View {
        List {
            ForEach(notes.containers) { container in
                ContainerRow(
                    container: container, busy: busyId == container.id, notes: notes, toasts: toasts,
                    setBusy: { busyId = $0 }
                )
                .listRowBackground(PaiPalette.Semantic.panelBackground)
            }
            if notes.containers.isEmpty {
                Text("No containers yet — add the folder your notes sync from.")
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paiScreenBackground()
        .navigationTitle("Containers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAdd = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add container")
            }
        }
        .task { await notes.refreshContainers() }
        .refreshable { await notes.refreshContainers() }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                AddContainerView(notes: notes) { showAdd = false }
            }
        }
    }
}

private struct ContainerRow: View {
    let container: NoteContainer
    let busy: Bool
    let notes: NotesStore
    let toasts: ToastCenter
    let setBusy: (String?) -> Void

    private static let stateLabel: [String: String] = [
        "pending": "Not scanned yet", "active": "Syncing",
        "paused_mass_delete": "Paused — mass deletion", "paused_missing_path": "Paused — path missing",
        "paused_error": "Paused — error", "disabled": "Disabled",
    ]

    private var stateColor: Color {
        switch container.state {
        case "active": PaiPalette.green500
        case "paused_mass_delete", "paused_missing_path", "paused_error": PaiPalette.red500
        default: PaiPalette.Semantic.textMuted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(container.name)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                if container.isDefault {
                    Text("default")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.accentText)
                }
                Spacer(minLength: 0)
                Toggle(
                    "",
                    isOn: Binding(
                        get: { container.enabled },
                        set: { enabled in Task { await toggleEnabled(enabled) } })
                )
                .labelsHidden()
                .disabled(busy)
            }

            Text("\(container.agentSlug) · \(container.path)")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(2)

            HStack(spacing: 12) {
                NavigationLink("Attachments") {
                    NoteAttachmentsScreen(containerId: container.id, containerName: container.name)
                }
                NavigationLink("Link health") {
                    NoteLinkHealthScreen(containerId: container.id)
                }
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.primary600)

            Text(Self.stateLabel[container.state] ?? container.state)
                .font(PaiTypography.caption.font)
                .foregroundStyle(stateColor)

            HStack(spacing: 12) {
                Text("\(container.noteCount) notes")
                Text("Last scan: \(container.lastScanAtMs.map(formatted) ?? "never")")
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)

            if let error = container.lastError, !error.isEmpty {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }

            if let breaker = container.breaker {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PaiPalette.amber700)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(breaker.pendingDeletions) of \(breaker.baselineCount) notes look deleted at once")
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.amber800)
                            if !breaker.names.isEmpty {
                                Text("e.g. \(breaker.names.joined(separator: ", "))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(PaiPalette.amber700)
                                    .lineLimit(1)
                            }
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Yes, they're deleted") { Task { await resume(.applyDeletions) } }
                            .buttonStyle(.borderedProminent)
                            .tint(PaiPalette.red600)
                        Button("No, restore from the database") { Task { await resume(.restoreFiles) } }
                            .buttonStyle(.bordered)
                    }
                    .font(PaiTypography.caption.font)
                    .disabled(busy)
                }
                .padding(8)
                .background(PaiPalette.amber50, in: RoundedRectangle(cornerRadius: 8))
            }

            if container.state == "paused_missing_path" {
                Text(container.pausedReason ?? "This folder isn't reachable on the VM right now.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.amber800)
                    .padding(8)
                    .background(PaiPalette.amber50, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task {
                    setBusy(container.id)
                    let ok = await notes.deleteContainer(container.id)
                    setBusy(nil)
                    if !ok { toasts.show(notes.loadError ?? "Could not remove the container", kind: .error) }
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func toggleEnabled(_ enabled: Bool) async {
        setBusy(container.id)
        let ok = await notes.setContainerEnabled(container.id, enabled: enabled)
        setBusy(nil)
        if !ok { toasts.show(notes.loadError ?? "Could not update the container", kind: .error) }
    }

    private func resume(_ action: NoteContainerResumeAction) async {
        setBusy(container.id)
        let ok = await notes.resumeContainer(container.id, action: action)
        setBusy(nil)
        if !ok { toasts.show(notes.loadError ?? "Could not resume the container", kind: .error) }
    }

    private func formatted(_ ms: Int) -> String {
        Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AddContainerView: View {
    let notes: NotesStore
    let onCreated: () -> Void

    @State private var path = ""
    @State private var name = ""
    @State private var checking = false
    @State private var check: NoteContainerPathCheck?
    @State private var creating = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Absolute path on the VM", text: $path)
                    .onChange(of: path) { check = nil }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Name (optional)", text: $name)
            }
            Section {
                Button(checking ? "Checking…" : "Check path") { Task { await validate() } }
                    .disabled(checking || path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let check {
                    Text(checkSummary(check))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(check.ok ? PaiPalette.green600 : PaiPalette.Semantic.errorText)
                }
                if let error {
                    Text(error).font(PaiTypography.caption.font).foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        }
        .navigationTitle("Add container")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(creating ? "Adding…" : "Add") { Task { await create() } }
                    .disabled(check?.ok != true || creating)
            }
        }
    }

    private func checkSummary(_ check: NoteContainerPathCheck) -> String {
        guard check.ok else { return check.reason ?? "Can't use this path." }
        guard let count = check.existingNotes else { return "Looks good." }
        return "Looks good — \(count) markdown files already there."
    }

    private func validate() async {
        checking = true
        error = nil
        check = nil
        defer { checking = false }
        do {
            check = try await notes.validateContainerPath(path.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "Could not check the path"
        }
    }

    private func create() async {
        guard check?.ok == true else { return }
        creating = true
        defer { creating = false }
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            await notes.createContainer(path: trimmedPath, name: trimmedName.isEmpty ? trimmedPath : trimmedName) != nil
        else {
            error = notes.loadError ?? "Could not create the container"
            return
        }
        onCreated()
    }
}
