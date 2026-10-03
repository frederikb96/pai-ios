import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs. Sending the first message is not part of
/// it: that goes through ``OutboxStore``, which owns the request.
public protocol CreateSessionApiClient: Sendable {
    func getSessionTypes() async throws -> [SessionType]
    func getSessionModels() async throws -> SessionModelsResponse
}

extension PaiApiClient: CreateSessionApiClient {}

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
    /// entry (`home`), which happens to be this value too. Guards the regression
    /// `SessionTypePicker.tsx` documents: showing one type selected while the request that would
    /// actually fire launches another. Deliberately a SEPARATE constant from `fastSessionTypeId`
    /// below — the two used to share one value, but "what shows preselected" and "what counts as
    /// the fast sandbox" are different questions, and `isFastSelected` must keep answering the
    /// second one regardless of which type this screen defaults to.
    public static let preselectedSessionTypeId = "home"

    /// The fast sandbox's own id — what `isFastSelected` checks against, kept apart from
    /// `preselectedSessionTypeId` so a future change to the default never silently breaks the
    /// fast-specific UI (`resolvedModel`/`resolvedThinking` below, the fast caption in
    /// `ModelPickerSheet`) that has nothing to do with what the screen shows first.
    public static let fastSessionTypeId = "fast"

    /// The pod-resident worker's own id — what `isUltrafastSelected` checks against. Unlike
    /// `fastSessionTypeId` it is never a ConfigMap entry: it is offered the same way `fast` is,
    /// through `get_selectable_session_types`'s own built-ins, once the backend registers it.
    public static let ultrafastSessionTypeId = "ultrafast"

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
    /// What the fast sandbox launches with when nothing is chosen — read from `start()`'s own
    /// `GET /api/session-models` rather than hardcoded, so the picker never drifts from
    /// `agent/src/fast-sandbox.ts`'s actual default. These two are only what shows before that
    /// first fetch lands.
    public private(set) var fastDefaultModel = "sonnet"
    public private(set) var fastDefaultThinking = "low"

    /// Whether `selectedSessionTypeId` is the fast sandbox — the one type whose launch defaults
    /// to a model and thinking level of its own rather than the plan's.
    public var isFastSelected: Bool { selectedSessionTypeId == Self.fastSessionTypeId }

    /// Whether `selectedSessionTypeId` is the pod-resident worker — no Claude model, no Claude
    /// credential, and no attachments, so the create screen hides all three rather than offering
    /// controls that have nothing to act on.
    public var isUltrafastSelected: Bool { selectedSessionTypeId == Self.ultrafastSessionTypeId }

    /// What will actually launch if nothing more is chosen — an explicit selection always wins;
    /// unset falls back to the fast sandbox's own default on a fast session, and to the plan's
    /// own default (`nil`) everywhere else. For display only: leaving this untouched still sends
    /// no flag, exactly as before this picker offered a fast session any choice at all.
    public var resolvedModel: String? { selectedModel ?? (isFastSelected ? fastDefaultModel : nil) }
    public var resolvedThinking: String? {
        selectedThinking ?? (isFastSelected && resolvedModel == fastDefaultModel ? fastDefaultThinking : nil)
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
        if let response = try? await api.getSessionModels() {
            sessionModels = response.models
            fastDefaultModel = response.fastDefaultModel
            fastDefaultThinking = response.fastDefaultThinking
        }
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

    /// Any type but Custom drops a previously browsed directory: the directory is what makes a
    /// session custom, and a create carrying one launches there whatever type it names.
    public func selectSessionType(_ id: String) {
        selectedSessionTypeId = id
        if id != "custom" { workingDir = nil }
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

    /// Hands the first message to `outbox` and returns at once.
    ///
    /// **Nothing here waits for the network**, and that is the contract rather than an
    /// optimisation: the entry is on disk before this returns, so the send is already durable,
    /// and the session it creates arrives later on the outbox's own worker. What happens then —
    /// the row, and the id reaching the screen that composed it — is
    /// ``OutboxStore/installHandover(drafts:sessions:handoff:)``'s, which is the only place that knows a
    /// send has landed. Mirrors `MessageInput.tsx`'s `handleSend`: enqueue, clear the composer,
    /// and let the queue deliver it whenever the link allows.
    ///
    /// 🚨 **Do not make this await the entry's own terminal state.** It reads like the tidier
    /// shape and cannot work: the handover retires an entry the instant it is sent, so a caller
    /// polling `outbox.entries` for its own entry finds it gone rather than `.sent` — a created
    /// session, and no caller left to open it. Offline it is worse still: an await with nothing
    /// on screen to say the message was kept. What the reader sees while a send waits is
    /// ``OutboxStore/newSessionEntries()``, drawn as bubbles on the screen that composed it.
    public func enqueueSend(
        message: String, files: [PaiFileUpload] = [], draftAttachmentIds: [String] = [], outbox: OutboxStore
    ) {
        let inlineFiles = files.map { file in
            OutboxInlineFile(localId: UUID().uuidString, filename: file.filename, mimeType: file.mimeType)
        }
        let inlineFileData = Dictionary(
            uniqueKeysWithValues: zip(inlineFiles.map(\.localId), files.map(\.data)))
        // An ultra-fast session takes no directory, model or effort — the backend refuses a
        // create carrying any of them, so a previous visit's choice (this store is rebuilt per
        // visit, but `selectedModel`/`workingDir` can still be set earlier in the SAME visit
        // before the ultra-fast pill is picked) must never reach the request.
        outbox.enqueue(
            OutboxEntry(
                target: .newSession(
                    agent: selectedMachine, sessionType: selectedSessionTypeId,
                    workingDir: isUltrafastSelected ? nil : workingDir,
                    model: isUltrafastSelected ? nil : selectedModel,
                    thinking: isUltrafastSelected ? nil : selectedThinking),
                text: message, draftAttachmentIds: draftAttachmentIds, inlineFiles: inlineFiles
            ),
            inlineFileData: inlineFileData)
    }
}
