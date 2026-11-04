import PAIKit
import SwiftUI

/// The bar under a subagent's transcript, replacing the composer. A subagent cannot be written to
/// directly, so a message goes through its conversation and shows how far it got; Interrupt stops
/// this one agent and nothing else. Everything offered is what `SubagentControlsStore` read from
/// the backend, never worked out here. Port of `SubagentBar.tsx`.
///
/// The store is re-read when the agent's row or its conversation's row moves (the app-wide session
/// poll keeps both current), because nothing arrives on the agent's own stream when the controls
/// change; `pollWhilePending` covers the seconds in which a message is still on its way.
struct SubagentBar: View {
    let session: Session

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessions
    @Environment(ToastCenter.self) private var toasts

    @State private var store: SubagentControlsStore?

    var body: some View {
        // The store is built in `.task`, so the first frame has to render something or the task
        // would hang off an empty view and never run.
        VStack(alignment: .leading, spacing: 8) {
            if let store {
                content(store: store)
            } else {
                Text("This is a subagent's transcript.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .task(id: session.id) {
            guard let client = environment.connection?.apiClient else { return }
            let fresh = SubagentControlsStore(sessionId: session.id, api: client)
            store = fresh
            await fresh.refresh()
        }
        .task(id: store?.hasPending) {
            await store?.pollWhilePending()
        }
        .onChange(of: refreshCue) { _, _ in
            Task { await store?.refresh() }
        }
        .onChange(of: store?.actionError) { _, message in
            guard let message else { return }
            toasts.show(message, kind: .error)
            store?.clearActionError()
        }
        .fixtureFact("composer", "subagent-bar")
        .accessibilityIdentifier("subagent-bar")
    }

    /// Changes whenever the agent's row or its conversation's row does — the cue to ask again.
    private var refreshCue: [String?] {
        let parent = session.parentSessionId.flatMap { sessions.session(withId: $0) }
        let current = sessions.session(withId: session.id)
        return [
            current?.lastActivityAt,
            parent?.activityCounts.map { String($0.agents) },
            parent?.state.map { "\($0)" },
        ]
    }

    private var label: String { session.subagentName ?? session.subagentType ?? "this agent" }

    @ViewBuilder
    private func content(store: SubagentControlsStore) -> some View {
        let nudges = store.listedNudges
        if !nudges.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(nudges) { nudge in
                    nudgeRow(nudge)
                }
            }
        }

        if store.controls?.canNudge == true {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    "Message \(label) — it reaches it once its current run ends", text: Bindable(store).text,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .font(PaiTypography.body.font)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Message \(label)")
                .accessibilityIdentifier("subagent-message-field")

                Button {
                    Task { await store.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(store.canSend ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                        .frame(width: 44, height: 44)
                }
                .disabled(!store.canSend)
                .accessibilityLabel("Send to agent")
                .accessibilityIdentifier("subagent-send")
            }
        } else {
            Text(store.controls?.reason ?? "This is a subagent's transcript — read-only.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("subagent-read-only")
        }

        if store.controls == nil, let loadError = store.loadError {
            Text(loadError)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }

        HStack(alignment: .center, spacing: 8) {
            if let controls = store.controls, controls.canInterrupt {
                interruptControl(store: store, controls: controls)
            }
            Spacer(minLength: 0)
            if let parentSessionId = session.parentSessionId {
                Button("Open parent conversation") {
                    environment.router.push(.session(id: parentSessionId))
                }
                .font(PaiTypography.caption.font)
                .frame(minHeight: 36)
                .accessibilityIdentifier("subagent-open-parent")
            }
        }
    }

    @ViewBuilder
    private func interruptControl(store: SubagentControlsStore, controls: SubagentControls) -> some View {
        if store.isConfirmingInterrupt {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    controls.canResumeAfterInterrupt
                        ? "Stop \(label)? Its conversation is told; a message to it later resumes it."
                        : "Stop \(label) for good? It cannot be continued."
                )
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                HStack(spacing: 12) {
                    Button("Cancel") { store.isConfirmingInterrupt = false }
                        .disabled(store.isStopping)
                        .frame(minHeight: 36)
                    Button(confirmTitle(stopping: store.isStopping), role: .destructive) {
                        Task { await store.interrupt() }
                    }
                    .disabled(store.isStopping)
                    .frame(minHeight: 36)
                    .accessibilityIdentifier("subagent-interrupt-confirm")
                }
                .font(PaiTypography.caption.font)
            }
        } else {
            Button {
                store.isConfirmingInterrupt = true
            } label: {
                Label("Interrupt", systemImage: "stop.fill")
                    .font(PaiTypography.caption.font)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).strokeBorder(PaiPalette.Semantic.borderStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PaiPalette.Semantic.textSecondary)
            .accessibilityIdentifier("subagent-interrupt")
        }
    }

    private func confirmTitle(stopping: Bool) -> String {
        if stopping { return "Stopping…" }
        return session.subagentName != nil ? "Stop agent" : "Stop for good"
    }

    private func nudgeRow(_ nudge: SubagentNudge) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stateLabel(nudge.state))
                .font(PaiTypography.caption.font.weight(.medium))
                .foregroundStyle(stateForeground(nudge.state))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(stateBackground(nudge.state))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(nudgeText(nudge))
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("subagent-nudge")
    }

    private func nudgeText(_ nudge: SubagentNudge) -> String {
        var text = nudge.text
        if nudge.state == .failed, let error = nudge.error, !error.isEmpty { text += " — \(error)" }
        if nudge.reworded { text += " (the conversation reworded it)" }
        return text
    }

    private func stateLabel(_ state: SubagentNudge.Delivery) -> String {
        switch state {
        case .queued: "Queued"
        case .relayed: "Passed on"
        case .delivered: "Delivered"
        case .failed: "Failed"
        case .withdrawn: "Withdrawn"
        case .unrecognized(let raw): raw.capitalized
        }
    }

    private func stateForeground(_ state: SubagentNudge.Delivery) -> Color {
        switch state {
        case .failed: PaiPalette.Semantic.errorText
        case .delivered: PaiPalette.green700
        default: PaiPalette.Semantic.textSecondary
        }
    }

    private func stateBackground(_ state: SubagentNudge.Delivery) -> Color {
        switch state {
        case .failed: PaiPalette.Semantic.errorBackground
        case .delivered: PaiPalette.green100
        default: PaiPalette.Semantic.raisedSurface
        }
    }
}
