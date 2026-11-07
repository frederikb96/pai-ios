import Foundation
import Observation

public protocol DecisionsApiClient: Sendable {
    func getOpenDecisions() async throws -> OpenDecisionsResponse
    func answerDecisions(sessionId: String, answers: [DecisionAnswer], clientMessageId: String) async throws
        -> AnswerDecisionsResponse
    func withdrawDecision(sessionId: String, number: Int) async throws -> Decision
}

extension PaiApiClient: DecisionsApiClient {}

/// Every open decision across the owner's sessions, as the server last listed them. Swift port of
/// `stores/decisions.ts`. App-wide: the pin above a transcript, the Decisions app and the Apps
/// row's count all read the one list, refreshed on the notification stream's `decisions` event, on
/// every stream (re)connect and when a decision view appears.
///
/// Owner only: the routes answer a guest 403, which the API client reads as a rejected credential
/// and signs out, so `refresh()` asks `isOwner` before every request and a guest never sends one.
@MainActor
@Observable
public final class DecisionsStore {
    public private(set) var open: [Decision] = []

    private let api: DecisionsApiClient
    private let isOwner: @MainActor () -> Bool
    private var refreshSequence = 0

    public init(api: DecisionsApiClient, isOwner: @escaping @MainActor () -> Bool) {
        self.api = api
        self.isOwner = isOwner
    }

    /// One session's open decisions, by number.
    public func decisions(forSession sessionId: String) -> [Decision] {
        Self.sessionDecisions(open, sessionId: sessionId)
    }

    public nonisolated static func sessionDecisions(_ decisions: [Decision], sessionId: String) -> [Decision] {
        decisions.filter { $0.sessionId == sessionId }.sorted { $0.number < $1.number }
    }

    /// The open decisions grouped by session, the session with the newest decision first (the
    /// server lists newest first).
    public var groups: [DecisionGroup] {
        var order: [String] = []
        var titles: [String: String?] = [:]
        for decision in open where titles[decision.sessionId] == nil {
            order.append(decision.sessionId)
            titles[decision.sessionId] = .some(decision.sessionTitle)
        }
        return order.map {
            DecisionGroup(
                sessionId: $0, sessionTitle: titles[$0] ?? nil, decisions: decisions(forSession: $0))
        }
    }

    /// Best-effort: a failed read keeps what was shown until the next event or appearance.
    public func refresh() async {
        guard isOwner() else { return }
        refreshSequence += 1
        let sequence = refreshSequence
        guard let response = try? await api.getOpenDecisions() else { return }
        // A slower, older read must not overwrite a newer one.
        if sequence == refreshSequence { open = response.decisions }
    }

    /// Sends the answers of one session as one message. They leave `open` at once on success;
    /// a refusal (409: one was answered or withdrawn meanwhile, nothing was sent) rethrows and
    /// the list is re-read.
    public func answer(sessionId: String, answers: [DecisionAnswer]) async throws {
        do {
            _ = try await api.answerDecisions(
                sessionId: sessionId, answers: answers, clientMessageId: UUID().uuidString)
        } catch {
            await refresh()
            throw error
        }
        let answered = Set(answers.map(\.number))
        open.removeAll { $0.sessionId == sessionId && answered.contains($0.number) }
        await refresh()
    }

    /// Drops a decision the owner answered in the conversation instead.
    public func withdraw(_ decision: Decision) async throws {
        do {
            _ = try await api.withdrawDecision(sessionId: decision.sessionId, number: decision.number)
        } catch {
            await refresh()
            throw error
        }
        open.removeAll { $0.id == decision.id }
        await refresh()
    }
}

public struct DecisionGroup: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let sessionTitle: String?
    public let decisions: [Decision]
    public var id: String { sessionId }
}
