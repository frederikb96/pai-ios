import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol CreateSessionApiClient: Sendable {
    func getSessionTypes() async throws -> [SessionType]
    func postMessage(
        sessionId: String?, message: String, files: [PaiFileUpload], sessionType: String?, workingDir: String?,
        agent: String?
    ) async throws -> PostMessageResponse
}

extension PaiApiClient: CreateSessionApiClient {}

/// The outcome of `CreateSessionStore.create(message:files:)`.
public enum CreateSessionResult: Sendable, Equatable {
    case created(Session)
    case failed(String)
}

/// Swift port of the New Session screen's launch-choice state: `pai-cloud/web/src/components/
/// NewSessionView.tsx`'s machine/session-type wiring, `SessionTypePicker.tsx`'s preselect effect,
/// and `stores/session.ts`'s `createSession`.
///
/// **Does not own composer text or attachments, and does not itself write to the server.**
/// `selectedSessionTypeId`/`workingDir` below are this screen's in-memory picker state; the view
/// mirrors every change into `DraftStore`'s `DraftKey.newSession` entry, the same object holding
/// the composer text and debounced through the same 700ms `PUT` — one shared writer for the whole
/// `new` draft, not this store racing the text half for the same server row. `selectedMachine` is
/// the one choice that is never mirrored: see `reset()`.
@MainActor
@Observable
public final class CreateSessionStore {
    /// Preselected ahead of every configured type, and written into the choice rather than merely
    /// displayed — the server's own default for an omitted `session_type` is the first ConfigMap
    /// entry (`home`), not this. Guards the regression `SessionTypePicker.tsx` documents: showing
    /// "Fast" selected while the request that would actually fire launches "Home".
    public static let preselectedSessionTypeId = "fast"

    public private(set) var selectedMachine: String
    /// `nil` until preselection or an explicit choice has run — never left displaying a type the
    /// create request would not actually send.
    public private(set) var selectedSessionTypeId: String?
    public private(set) var workingDir: String?
    public private(set) var isCreating = false

    /// The legacy flat `/api/session-types` list — a fallback for `selectedMachine ==
    /// MachineStore.defaultMachineSlug` only, for a deployment that predates `/api/agents`.
    private var globalSessionTypes: [SessionType] = []
    private let machines: MachineStore
    private let api: CreateSessionApiClient

    public init(machines: MachineStore, api: CreateSessionApiClient) {
        self.machines = machines
        self.selectedMachine = MachineStore.defaultMachineSlug
        self.api = api
    }

    // MARK: - The view's surface

    /// The per-machine list wins; the flat legacy list is a fallback only for the default
    /// machine. A non-default machine reporting no list of its own yields an empty array —
    /// matching the web, where that also hides the Custom pill, since there is nothing to pick.
    public var availableSessionTypes: [SessionType] {
        if let machine = machines.machines.first(where: { $0.slug == selectedMachine }) {
            return machine.sessionTypes
        }
        return selectedMachine == MachineStore.defaultMachineSlug ? globalSessionTypes : []
    }

    /// Resets to a fresh visit's state. The machine choice is deliberately never remembered
    /// between visits — "a sticky choice is how a session ends up on the wrong machine a week
    /// after the reason for picking the laptop is forgotten" (`AgentPicker.tsx`).
    public func reset() {
        selectedMachine = MachineStore.defaultMachineSlug
        selectedSessionTypeId = nil
        workingDir = nil
    }

    /// Loads the legacy global session-type list and applies the initial preselection. Call once
    /// when the screen appears.
    public func start() async {
        globalSessionTypes = (try? await api.getSessionTypes()) ?? globalSessionTypes
        applyPreselectionIfNeeded()
    }

    /// Call again whenever `MachineStore.machines` may have just changed. This store has no
    /// reactive dependency on that one — nothing here re-derives the preselection on its own —
    /// so a caller that refreshes machines after `start()` (the ordinary case: machines arrive
    /// from their own poll) is responsible for calling this again once they do.
    public func applyPreselectionIfNeeded() {
        guard selectedSessionTypeId == nil, !availableSessionTypes.isEmpty else { return }
        let preselected =
            availableSessionTypes.first { $0.id == Self.preselectedSessionTypeId } ?? availableSessionTypes[0]
        selectedSessionTypeId = preselected.id
    }

    /// Changing the machine clears both other choices: each machine's type list is its own (ids
    /// can coincide across unrelated types), and a browsed directory is a `/home/frederik/...`
    /// path meaning a different tree per machine — carrying one over would drop a
    /// `bypassPermissions` session into the wrong machine's checkout. Re-admits the preselect
    /// rule immediately, for the new machine's own types.
    public func selectMachine(_ slug: String) {
        selectedMachine = slug
        workingDir = nil
        selectedSessionTypeId = nil
        applyPreselectionIfNeeded()
    }

    public func selectSessionType(_ id: String) {
        selectedSessionTypeId = id
    }

    /// A chosen directory is what makes a session custom, so the two always move together.
    /// `nil` (Cancel, or an explicit Clear) drops back to no type, which immediately re-admits
    /// the preselect rule to choose `fast`/the first type again.
    public func selectWorkingDir(_ path: String?) {
        workingDir = path
        selectedSessionTypeId = path != nil ? "custom" : nil
        applyPreselectionIfNeeded()
    }

    /// Creates the session and returns the optimistic `Session` its row should show immediately,
    /// mirroring `createSession`'s hand-built row in `stores/session.ts` field for field —
    /// `remote_control: true` here is optimistic and technically premature (ported as-is; the
    /// real value arrives on the next poll). The caller — not this store — is responsible for
    /// inserting it (`SessionListStore.prependOptimisticSession(_:)`), tracking the first message
    /// bubble, and navigating to the resulting chat: none of those are session-creation state.
    public func create(message: String, files: [PaiFileUpload] = []) async -> CreateSessionResult {
        isCreating = true
        defer { isCreating = false }
        let type = selectedSessionTypeId
        let dir = workingDir
        let machine = selectedMachine
        do {
            let result = try await api.postMessage(
                sessionId: nil, message: message, files: files, sessionType: type, workingDir: dir, agent: machine
            )
            let now = ISO8601DateFormatter().string(from: Date())
            let optimistic = Session(
                id: result.sessionId,
                sessionType: type ?? globalSessionTypes.first?.id ?? "default",
                status: .pending,
                state: .starting,
                blocker: nil,
                working: nil,
                title: nil,
                titleLocked: nil,
                initialMessage: message,
                sessionTokens: 0,
                claudeSessionId: nil,
                idleTimeoutMinutes: nil,
                effectiveIdleTimeoutMinutes: nil,
                cseId: nil,
                createdAt: now,
                updatedAt: now,
                lastActivityAt: now,
                workingDir: dir,
                agent: machine,
                kind: .conversation,
                parentSessionId: nil,
                subagentName: nil,
                subagentType: nil,
                subagentDescription: nil,
                remoteControl: true,
                discovered: nil,
                projectId: nil,
                phaseId: nil,
                projectName: nil
            )
            return .created(optimistic)
        } catch {
            return .failed((error as? PaiError)?.userMessage ?? "Failed to create session")
        }
    }
}
