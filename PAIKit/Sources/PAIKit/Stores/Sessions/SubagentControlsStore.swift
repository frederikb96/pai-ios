import Foundation
import Observation

/// The narrow slice of `PaiApiClient` the subagent bar needs.
public protocol SubagentControlsApiClient: Sendable {
    func getSubagentControls(sessionId: String) async throws -> SubagentControlsResponse
    func sendSubagentNudge(sessionId: String, text: String) async throws -> SubagentNudgeResponse
    func interruptSubagent(sessionId: String) async throws -> SubagentInterruptResponse
}

extension PaiApiClient: SubagentControlsApiClient {}

/// What the bar under a subagent's transcript offers and shows — Swift port of
/// `useSubagentControls.ts` and the state half of `SubagentBar.tsx`.
///
/// A subagent cannot be written to directly, so a message goes through its conversation and shows
/// how far it got; Interrupt stops this one agent and nothing else. Everything offered is what
/// `GET …/subagent-controls` says, never worked out here. Nothing arrives on the agent's own stream
/// when those answers change, so the store is re-read on opening, whenever the view reports that
/// the agent's or its conversation's row moved (``refresh()``), every ``pendingPollInterval``
/// while a message is still on its way (``pollWhilePending()``), and after a send or an interrupt.
@MainActor
@Observable
public final class SubagentControlsStore {
    /// How often the messages still on their way are re-read.
    public static let pendingPollInterval: Duration = .seconds(3)
    /// How many past messages stay listed above the field.
    public static let listedNudges = 3

    /// What is typed for each agent, kept while the reader moves between a session's agents.
    private static let drafts = DraftBox()

    public let sessionId: String
    public private(set) var response: SubagentControlsResponse?
    /// Why the read failed, shown only while there is nothing to show.
    public private(set) var loadError: String?
    public private(set) var isSending = false
    public private(set) var isStopping = false
    /// The last send or interrupt that failed, for a toast.
    public private(set) var actionError: String?
    public var isConfirmingInterrupt = false

    public var text: String {
        didSet { Self.drafts.texts[sessionId] = text }
    }

    private let api: SubagentControlsApiClient
    private var latestRead = 0

    public init(sessionId: String, api: SubagentControlsApiClient) {
        self.sessionId = sessionId
        self.api = api
        self.text = Self.drafts.texts[sessionId] ?? ""
    }

    public var controls: SubagentControls? { response?.controls }

    /// The last few messages, oldest first.
    public var listedNudges: [SubagentNudge] {
        Array((response?.nudges ?? []).suffix(Self.listedNudges))
    }

    public var hasPending: Bool {
        response?.nudges.contains { $0.state.isInFlight } ?? false
    }

    public var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    /// Reads the controls again. An answer that arrives after a newer read started is dropped.
    public func refresh() async {
        latestRead += 1
        let mine = latestRead
        do {
            let next = try await api.getSubagentControls(sessionId: sessionId)
            guard mine == latestRead else { return }
            response = next
            loadError = nil
        } catch {
            guard mine == latestRead else { return }
            loadError = (error as? PaiError)?.userMessage ?? "Could not read what this agent can do"
        }
    }

    /// Re-reads every ``pendingPollInterval`` for as long as a message is on its way. Cancelled by
    /// the view's `.task(id:)` when the pending state ends or the screen goes.
    public func pollWhilePending() async {
        while hasPending {
            try? await Task.sleep(for: Self.pendingPollInterval)
            if Task.isCancelled { return }
            await refresh()
        }
    }

    /// Sends the typed text. A failure keeps the text for another try.
    public func send() async {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending else { return }
        isSending = true
        actionError = nil
        defer { isSending = false }
        do {
            _ = try await api.sendSubagentNudge(sessionId: sessionId, text: message)
            text = ""
            await refresh()
        } catch {
            actionError = (error as? PaiError)?.userMessage ?? "Could not send the message"
        }
    }

    /// Stops this agent. The confirmation closes on success; the controls are read again either way.
    public func interrupt() async {
        isStopping = true
        actionError = nil
        defer { isStopping = false }
        do {
            _ = try await api.interruptSubagent(sessionId: sessionId)
            isConfirmingInterrupt = false
        } catch {
            actionError = (error as? PaiError)?.userMessage ?? "Could not stop the agent"
        }
        await refresh()
    }

    public func clearActionError() {
        actionError = nil
    }
}

/// The typed-but-unsent text per agent, outliving the store that shows it.
@MainActor
private final class DraftBox {
    var texts: [String: String] = [:]
}
