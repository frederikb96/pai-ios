import PAIKit
import SwiftUI

/// What the composer becomes when PAI is not driving this session — a common, healthy state, not
/// an error. Ports `MessageInput.tsx`'s four variants exactly: the composer is *replaced*, never
/// merely disabled, because the four messages below explain four genuinely different situations a
/// disabled text field cannot distinguish.
struct NonDrivableComposerBar: View {
    @Environment(AppEnvironment.self) private var environment
    let session: Session
    let machines: MachineStore

    @State private var isResuming = false
    @State private var showsCollideConfirm = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch variant {
            case .subagent:
                Text("This is a subagent's transcript — read-only.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                if let parentSessionId = session.parentSessionId {
                    Button("Open parent conversation") {
                        environment.router.push(.session(id: parentSessionId))
                    }
                }

            case .machineOffline(let machineName):
                Text("\(machineName) is offline — this session can be resumed once it is back.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                Button("Resume here") {}
                    .disabled(true)

            case .collideConfirm:
                Text("This session isn't being driven by PAI right now.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                if showsCollideConfirm {
                    Text(
                        "This conversation is already connected to Remote Control — most likely a terminal you still have open. Resuming starts a second process on it; close the other one first."
                    )
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                    HStack {
                        Button("Cancel") { showsCollideConfirm = false }
                        Button("Resume anyway") { Task { await resume() } }
                    }
                } else {
                    Button("Resume here") { showsCollideConfirm = true }
                }

            case .plainResume:
                Text("This session isn't being driven by PAI right now.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                Button(isResuming ? "Resuming…" : "Resume here") { Task { await resume() } }
                    .disabled(isResuming)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Matches `ComposerBar`'s own material — the same bar, replaced, not a different chrome.
        .background(.bar)
        .accessibilityIdentifier("non-drivable-composer")
    }

    private enum Variant {
        case subagent
        case machineOffline(String)
        case collideConfirm
        case plainResume
    }

    private var variant: Variant {
        if session.kind == .subagent { return .subagent }
        let machineSlug = session.agent ?? MachineStore.defaultMachineSlug
        if let machine = machines.allMachines.first(where: { $0.slug == machineSlug }), !machine.online {
            return .machineOffline(machine.displayName)
        }
        let mayCollide = (session.discovered ?? false) && (session.remoteControl ?? false) && session.kind != .subagent
        return mayCollide ? .collideConfirm : .plainResume
    }

    private func resume() async {
        isResuming = true
        errorMessage = nil
        defer { isResuming = false }
        do {
            guard let apiClient = environment.connection?.apiClient else { return }
            _ = try await apiClient.resumeSession(sessionId: session.id)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not resume this session."
        }
    }
}
