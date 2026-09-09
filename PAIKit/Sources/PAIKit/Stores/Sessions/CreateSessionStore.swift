import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol CreateSessionApiClient: Sendable {
    func getSessionTypes() async throws -> [SessionType]
    func getSessionModels() async throws -> [SessionModelInfo]
    func postMessage(
        sessionId: String?, message: String, files: [PaiFileUpload], sessionType: String?, workingDir: String?,
        agent: String?, model: String?, thinking: String?
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

    /// Session types built into the pod rather than the ConfigMap (see
    /// `backend/src/pai_cloud/config.py`'s `WEBSEARCH_SESSION_TYPE_ID`) sink under Custom rather
    /// than sitting at the top level next to home and fast — Freddy's own wording: the top-level
    /// list stays short as environments are added, and Custom's directory browser gets a section
    /// below Favourites listing these instead. A deny list rather than an allow list, mirroring
    /// the web's own `sessionTypes.ts` exactly: every ConfigMap-defined type (not just `home`)
    /// stays at the top level automatically, so adding a second one there needs no change here.
    public static let sunkSessionTypeIds: Set<String> = ["websearch", "confined"]

    /// Never offered as something to start, top-level or sunk — mirrors the web's
    /// `EXCLUDED_SESSION_TYPE_IDS`. `supervisor` is an internal conversation kind attached from a
    /// session's own menu; a pill for it here would let it be launched as an ordinary session,
    /// defeating "opened only from the session it watches".
    public static let excludedSessionTypeIds: Set<String> = ["supervisor"]

    /// `claude --model` aliases the picker offers, in display order. Mirrors the web's shared
    /// `ModelSelect.tsx` `MODEL_OPTIONS` — short aliases only, so there is no id table here to
    /// fall out of date as Anthropic reassigns what each tier resolves to. Also the model-only
    /// pickers that have no thinking dimension of their own (`SupervisionView`, the scheduler's
    /// `TaskEditorView`) — the model + thinking picker below reads it for display labels only,
    /// never for which models actually exist (that always comes from `sessionModels`).
    public static let modelOptions: [(id: String?, label: String)] = [
        (nil, "Default"), ("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus"), ("fable", "Fable"),
    ]

    /// Presentation only — the set of levels a model actually accepts always comes from
    /// `sessionModels` below (`GET /api/session-models`), never from this map. A level this map
    /// doesn't know falls back to its own id rather than disappearing.
    public static let effortLevelLabels: [String: String] = [
        "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra High", "max": "Max",
    ]

    /// `modelOptions` above, keyed for a lookup by id — every real alias (`Default`'s `nil` id
    /// dropped, since that case is spelled out at each call site instead).
    public static let modelDisplayLabels: [String: String] = Dictionary(
        uniqueKeysWithValues: modelOptions.compactMap { option in option.id.map { ($0, option.label) } })

    /// What the fast sandbox launches with when nothing is chosen (`agent/src/fast-sandbox.ts`) —
    /// held here so the picker never claims "Default" for a launch that is anything but. An
    /// explicit choice always overrides this; it is purely what gets pre-selected and displayed.
    public static let fastDefaultModel = "sonnet"
    public static let fastDefaultThinking = "low"

    public private(set) var selectedMachine: String
    /// `nil` until preselection or an explicit choice has run — never left displaying a type the
    /// create request would not actually send.
    public private(set) var selectedSessionTypeId: String?
    public private(set) var workingDir: String?
    public private(set) var selectedModel: String?
    /// A `claude --effort` level — only meaningful alongside `selectedModel`. `nil` lets Claude
    /// Code pick the plan's own default.
    public private(set) var selectedThinking: String?
    /// Every `claude --model` alias and the `claude --effort` levels it supports — the model
    /// picker's own data, fetched once by `start()` so it never hand-mirrors
    /// `config.SESSION_MODEL_EFFORT_LEVELS`.
    public private(set) var sessionModels: [SessionModelInfo] = []
    public private(set) var isCreating = false

    /// Whether `selectedSessionTypeId` is the fast sandbox — the one type whose launch defaults
    /// to a model and thinking level of its own rather than the plan's.
    public var isFastSelected: Bool { selectedSessionTypeId == Self.preselectedSessionTypeId }

    /// What will actually launch if nothing more is chosen — an explicit selection always wins;
    /// unset falls back to the fast sandbox's own default on a fast session, and to the plan's
    /// own default (`nil`) everywhere else. For display only: leaving this untouched still sends
    /// no flag, exactly as before this picker offered a fast session any choice at all.
    public var resolvedModel: String? { selectedModel ?? (isFastSelected ? Self.fastDefaultModel : nil) }
    public var resolvedThinking: String? {
        selectedThinking ?? (isFastSelected && resolvedModel == Self.fastDefaultModel ? Self.fastDefaultThinking : nil)
    }
    /// The effort levels the currently active model accepts — empty for "Default" (no model
    /// resolved) or for a model that declares none of its own.
    public var effortLevelsForResolvedModel: [String] {
        guard let resolvedModel else { return [] }
        return sessionModels.first { $0.id == resolvedModel }?.effortLevels ?? []
    }

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

    /// The top-level picker's own pills — see `sunkSessionTypeIds`'s doc comment.
    public var primarySessionTypes: [SessionType] {
        availableSessionTypes.filter {
            !Self.sunkSessionTypeIds.contains($0.id) && !Self.excludedSessionTypeIds.contains($0.id)
        }
    }

    /// Everything else a machine offers, shown inside the Custom directory browser below its
    /// favourites rather than at the top level.
    public var environmentSessionTypes: [SessionType] {
        availableSessionTypes.filter {
            Self.sunkSessionTypeIds.contains($0.id) && !Self.excludedSessionTypeIds.contains($0.id)
        }
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
        sessionModels = (try? await api.getSessionModels()) ?? sessionModels
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

    public func selectModel(_ id: String?) {
        selectedModel = id
        // The set of thinking levels a model accepts is a property of that model
        // (`sessionModels`), so a level chosen for the previous one is not necessarily valid for
        // this one — clear it rather than risk sending a combination the launch would reject.
        selectedThinking = nil
    }

    public func selectThinking(_ id: String?) {
        selectedThinking = id
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
        let model = selectedModel
        let thinking = selectedThinking
        do {
            let result = try await api.postMessage(
                sessionId: nil, message: message, files: files, sessionType: type, workingDir: dir, agent: machine,
                model: model, thinking: thinking
            )
            let now = ISO8601DateFormatter().string(from: Date())
            let optimistic = Session(
                id: result.sessionId,
                sessionType: type ?? globalSessionTypes.first?.id ?? "default",
                model: model,
                thinking: thinking,
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
