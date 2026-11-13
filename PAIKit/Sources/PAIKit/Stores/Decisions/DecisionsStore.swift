import Foundation
import Observation

public protocol DecisionsApiClient: Sendable {
    func getOpenDecisions() async throws -> OpenDecisionsResponse
    func getSessionDecisions(sessionId: String) async throws -> SessionDecisionsResponse
    func answerDecisions(sessionId: String, answers: [DecisionAnswer], clientMessageId: String) async throws
        -> AnswerDecisionsResponse
    func withdrawDecision(sessionId: String, number: Int) async throws -> Decision
}

extension PaiApiClient: DecisionsApiClient {}

/// A picked answer, and the version of the decision it was picked on: a decision the agent changed
/// since is refused by the server rather than answered.
public struct DecisionPick: Equatable, Sendable {
    public let text: String
    public let updatedAt: String

    public init(text: String, updatedAt: String) {
        self.text = text
        self.updatedAt = updatedAt
    }
}

/// Every open decision across the owner's sessions, every decision of each session a transcript
/// shows, and the answers picked and not yet sent or added to a message. Swift port of `stores/decisions.ts`. App-wide:
/// the pin above a transcript, the cards inside its replies, the Decisions app and the Apps row's
/// count all read it, refreshed on the notification stream's `decisions` event, on every stream
/// (re)connect and when a decision view appears.
///
/// Owner only: the routes answer a guest 403, so every read asks `capabilities` first and a guest
/// never sends one.
@MainActor
@Observable
public final class DecisionsStore {
    public private(set) var open: [Decision] = []
    /// Every decision, in any state, of each session a transcript watches, by number — what the
    /// cards inside its replies draw. A session is absent until its first read lands.
    public private(set) var bySession: [String: [Decision]] = [:]
    /// Answers picked and not sent yet, per session and decision number. One set however many
    /// surfaces show a session's decisions (the pin, the cards in its replies, the Decisions app),
    /// so a Send anywhere sends all of them as one message.
    public private(set) var picks: [String: [Int: DecisionPick]] = [:]

    private let api: DecisionsApiClient
    private let capabilities: @MainActor () -> Capabilities
    /// Reads are numbered as they start; a response applies only when it is newer than the last
    /// one applied. Judging by "newest started" instead would let a newer read that failed or was
    /// cancelled void an older one that succeeded, leaving the list as it was.
    private var refreshSequence = 0
    private var appliedRefresh = 0
    private var sessionSequences: [String: Int] = [:]
    private var appliedSession: [String: Int] = [:]
    /// How many shown transcripts watch each session.
    private var watchers: [String: Int] = [:]

    public init(api: DecisionsApiClient, capabilities: @escaping @MainActor () -> Capabilities) {
        self.api = api
        self.capabilities = capabilities
    }

    /// Whether this account may see decisions at all; a guest's transcript shows a marker line as
    /// the text it is.
    public var ownerMayDecide: Bool { capabilities().canOpenDecisions }

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

    /// Best-effort: a failed read keeps what was shown until the next event or appearance. Re-reads
    /// every watched session's decisions too.
    public func refresh() async {
        guard capabilities().canOpenDecisions else { return }
        refreshSequence += 1
        let sequence = refreshSequence
        if let response = try? await api.getOpenDecisions(), sequence > appliedRefresh {
            // A slower, older read must not overwrite a newer one.
            appliedRefresh = sequence
            open = response.decisions
        }
        for sessionId in watchers.keys.sorted() {
            await loadSession(sessionId)
        }
    }

    /// Keeps one session's decisions read while a transcript of it is shown, starting with a read
    /// now. Pair every call with ``unwatch(sessionId:)``.
    public func watch(sessionId: String) async {
        watchers[sessionId, default: 0] += 1
        await loadSession(sessionId)
    }

    public func unwatch(sessionId: String) {
        let left = (watchers[sessionId] ?? 1) - 1
        watchers[sessionId] = left > 0 ? left : nil
    }

    private func loadSession(_ sessionId: String) async {
        guard capabilities().canOpenDecisions else { return }
        let sequence = (sessionSequences[sessionId] ?? 0) + 1
        sessionSequences[sessionId] = sequence
        guard let response = try? await api.getSessionDecisions(sessionId: sessionId),
            sequence > (appliedSession[sessionId] ?? 0)
        else { return }
        appliedSession[sessionId] = sequence
        bySession[sessionId] = response.decisions
    }

    // MARK: - Picks

    /// Picks an answer without sending it, or takes it back when it is the one already picked.
    public func pick(_ text: String, for decision: Decision) {
        var session = picks[decision.sessionId] ?? [:]
        if session[decision.number]?.text == text {
            session[decision.number] = nil
        } else {
            session[decision.number] = DecisionPick(text: text, updatedAt: decision.updatedAt)
        }
        picks[decision.sessionId] = session
    }

    /// Makes `text` the picked answer, replacing any other, or removes the pick when it is empty:
    /// the owner's own words, kept as they are typed.
    public func setPick(_ text: String, for decision: Decision) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var session = picks[decision.sessionId] ?? [:]
        session[decision.number] = trimmed.isEmpty ? nil : DecisionPick(text: trimmed, updatedAt: decision.updatedAt)
        picks[decision.sessionId] = session.isEmpty ? nil : session
    }

    /// The pick for `decision` when it is none of the offered options, i.e. the owner's own words.
    public func ownWordsPick(for decision: Decision) -> String? {
        guard let picked = picked(sessionId: decision.sessionId, number: decision.number),
            !decision.options.contains(picked)
        else { return nil }
        return picked
    }

    /// Picks each decision's recommendation, replacing any pick for the same decisions.
    public func pickAllRecommended(_ decisions: [Decision]) {
        for decision in decisions {
            picks[decision.sessionId, default: [:]][decision.number] = DecisionPick(
                text: decision.recommendation, updatedAt: decision.updatedAt)
        }
    }

    public func clearPicks(sessionId: String) {
        picks[sessionId] = nil
    }

    /// The answer picked for decision `number` of a session, if any.
    public func picked(sessionId: String, number: Int) -> String? {
        picks[sessionId]?[number]?.text
    }

    /// The session's picks still worth sending, by number, each naming the version it was picked
    /// on: those whose decision is open as far as this client knows. The session's own listing
    /// wins where it has the decision (it is read in every state); the open list decides the rest.
    public func pendingAnswers(sessionId: String) -> [DecisionAnswer] {
        guard let session = picks[sessionId], !session.isEmpty else { return [] }
        var listedState: [Int: DecisionState] = [:]
        for decision in bySession[sessionId] ?? [] { listedState[decision.number] = decision.state }
        var openHere = Set<Int>()
        for decision in open where decision.sessionId == sessionId { openHere.insert(decision.number) }
        var answers: [DecisionAnswer] = []
        for (number, pick) in session {
            let stillOpen = listedState[number].map { $0 == .open } ?? openHere.contains(number)
            if stillOpen {
                answers.append(DecisionAnswer(number: number, answer: pick.text, updatedAt: pick.updatedAt))
            }
        }
        return answers.sorted { $0.number < $1.number }
    }

    // MARK: - Adding to the composer

    /// Puts every pending pick of the session into its composer draft as an answer line, after
    /// what the draft holds, drops those picks and asks the composer for focus. Nothing is sent:
    /// the owner sends the draft with whatever else he writes or records, and the server marks a
    /// decision answered when a message carries its line (``DecisionAnswerLine``). Returns whether
    /// anything was added.
    @discardableResult
    public func addPicksToMessage(sessionId: String, drafts: DraftStore) -> Bool {
        let known = bySession[sessionId] ?? open.filter { $0.sessionId == sessionId }
        var lines: [String] = []
        for answer in pendingAnswers(sessionId: sessionId) {
            guard let decision = known.first(where: { $0.number == answer.number }) else { continue }
            lines.append(DecisionAnswerLine.line(for: decision, answer: answer.answer))
        }
        guard !lines.isEmpty else { return false }
        drafts.setDraftText(
            key: sessionId, text: DecisionAnswerLine.appending(lines, toDraft: drafts.draft(for: sessionId).text))
        clearPicks(sessionId: sessionId)
        drafts.requestComposerFocus()
        return true
    }

    // MARK: - Sending

    /// Sends the answers of one session as one message of their own, for the Decisions app, which
    /// has no composer to put them in. On success they leave `open` at once, the
    /// session's listing takes the answered rows the server returned, and their picks are dropped;
    /// a refusal (409: one was answered, withdrawn or changed meanwhile, nothing was sent) rethrows
    /// and the lists are re-read.
    public func answer(sessionId: String, answers: [DecisionAnswer]) async throws {
        let response: AnswerDecisionsResponse
        do {
            response = try await api.answerDecisions(
                sessionId: sessionId, answers: answers, clientMessageId: UUID().uuidString)
        } catch {
            await refresh()
            throw error
        }
        let answered = Set(answers.map(\.number))
        open.removeAll { $0.sessionId == sessionId && answered.contains($0.number) }
        merge(response.answered, intoSession: sessionId)
        dropPicks(sessionId: sessionId, numbers: answered)
        await refresh()
    }

    /// Drops a decision the owner answered in the conversation instead.
    public func withdraw(_ decision: Decision) async throws {
        let withdrawn: Decision
        do {
            withdrawn = try await api.withdrawDecision(sessionId: decision.sessionId, number: decision.number)
        } catch {
            await refresh()
            throw error
        }
        open.removeAll { $0.id == decision.id }
        merge([withdrawn], intoSession: decision.sessionId)
        dropPicks(sessionId: decision.sessionId, numbers: [decision.number])
        await refresh()
    }

    /// The session's listing with these rows in place of their earlier versions; a session never
    /// read stays unread rather than becoming one with only these.
    private func merge(_ rows: [Decision], intoSession sessionId: String) {
        guard let listed = bySession[sessionId], !rows.isEmpty else { return }
        let byNumber = Dictionary(rows.map { ($0.number, $0) }, uniquingKeysWith: { _, newer in newer })
        bySession[sessionId] = listed.map { byNumber[$0.number] ?? $0 }
    }

    private func dropPicks(sessionId: String, numbers: Set<Int>) {
        guard var session = picks[sessionId] else { return }
        for number in numbers { session[number] = nil }
        picks[sessionId] = session.isEmpty ? nil : session
    }
}

public struct DecisionGroup: Sendable, Equatable, Identifiable {
    public let sessionId: String
    public let sessionTitle: String?
    public let decisions: [Decision]
    public var id: String { sessionId }
}
