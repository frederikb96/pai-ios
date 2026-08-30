import Foundation

/// A bubble this app is showing for a send of its own, until the server's ``PendingSend`` list
/// takes over showing it.
///
/// Exists only to cover the round trip: the moment a status event lists the send, the server's
/// own list draws it instead, and this is dropped. So a local bubble is never the thing that
/// decides whether a message arrived — see ``TranscriptStore/trackSend(sessionId:text:send:)``.
public struct PendingMessage: Equatable, Sendable {
    /// Identifies the bubble before the send request has answered with a row id.
    public let localId: Int
    public let text: String
    /// The outgoing row it became, once the send request has answered.
    public var outboxId: Int?

    public init(localId: Int, text: String, outboxId: Int?) {
        self.localId = localId
        self.text = text
        self.outboxId = outboxId
    }
}

/// What the server reports about one session's undelivered messages.
public struct TranscriptDelivery: Equatable, Sendable {
    /// Every send with no transcript entry yet — queued and relayed alike. Server-derived, so it
    /// is the same on every device and survives a reload.
    public var pendingSends: [PendingSend]
    public var lastError: String?

    public static let empty = TranscriptDelivery(pendingSends: [], lastError: nil)

    public init(pendingSends: [PendingSend], lastError: String?) {
        self.pendingSends = pendingSends
        self.lastError = lastError
    }
}

extension TranscriptStore {

    /// Per session rather than a single slot: it arrives on one session's status events and is
    /// read while another may be on screen, and a single slot would show one session's queue
    /// under the other's transcript for as long as it took the new session's first status event
    /// to land.
    public func delivery(for sessionId: String?) -> TranscriptDelivery {
        guard let sessionId else { return .empty }
        return delivery[sessionId] ?? .empty
    }

    /// Adopts the server's list of undelivered sends for a session, fed from every SSE `status`
    /// event.
    ///
    /// Hands over: a local bubble whose `outboxId` this list now names is dropped, since the
    /// server's copy draws it from now on. A send the list does *not* name is left alone — a
    /// status event produced before the send reached the database cannot know about it yet, and
    /// dropping the bubble on that would blink the message off screen and back.
    public func setDelivery(sessionId: String, pendingSends: [PendingSend], lastError: String?) {
        delivery[sessionId] = TranscriptDelivery(pendingSends: pendingSends, lastError: lastError)

        guard let queue = pendingMessages[sessionId] else { return }
        let named = Set(pendingSends.map(\.id))
        let hasNamedBubble = queue.contains { outboxId in
            guard let outboxId = outboxId.outboxId else { return false }
            return named.contains(outboxId)
        }
        guard hasNamedBubble else { return }
        pendingMessages[sessionId] = queue.filter { message in
            guard let outboxId = message.outboxId else { return true }
            return !named.contains(outboxId)
        }
    }

    /// Show a bubble for a send, and let the send itself decide how long it lives: it is named
    /// by the outgoing row the request answers with, and dropped outright if the request fails.
    ///
    /// Taking the in-flight request rather than a handle returned separately is the whole point.
    /// A bubble whose row is never named cannot be cleared by anything — not by the entry
    /// confirming it, not by the server's list, not by leaving the session — and the only way to
    /// produce one was a caller that forgot a second call. There is no second call here: this
    /// method awaits `send` itself.
    public func trackSend(sessionId: String, text: String, send: Task<PostMessageResponse, Error>) {
        localBubbleCounter += 1
        let localId = localBubbleCounter
        pendingMessages[sessionId, default: []].append(PendingMessage(localId: localId, text: text, outboxId: nil))

        Task { [weak self] in
            do {
                let result = try await send.value
                self?.resolveTrackedSend(sessionId: sessionId, localId: localId, outboxId: result.messageId)
            } catch {
                // Nothing to wait on: a bubble with no row behind it can never be told it
                // arrived, so it must not be left on screen.
                self?.dropTrackedSend(sessionId: sessionId, localId: localId)
            }
        }
    }

    private func resolveTrackedSend(sessionId: String, localId: Int, outboxId: Int) {
        guard var queue = pendingMessages[sessionId],
            let index = queue.firstIndex(where: { $0.localId == localId })
        else { return }
        queue[index].outboxId = outboxId
        pendingMessages[sessionId] = queue
        // The entry confirming it may already be in the store — a fast turn can land before its
        // own send request has answered.
        reconcilePending(sessionId)
    }

    private func dropTrackedSend(sessionId: String, localId: Int) {
        guard var queue = pendingMessages[sessionId] else { return }
        queue.removeAll { $0.localId == localId }
        pendingMessages[sessionId] = queue
    }

    /// Drop the bubbles whose send has arrived, told by the id the server put on the confirming
    /// entry. Nothing here looks at what the entry *is*: the whole point of the tag is that a
    /// send's entry can be a user message, a command, an attachment or a system line, and only
    /// the server knows which one answered which send.
    public func reconcilePending(_ sessionId: String) {
        guard let queue = pendingMessages[sessionId], !queue.isEmpty else { return }
        let confirmed = Set((messages[sessionId] ?? []).compactMap(\.outboxId))
        guard !confirmed.isEmpty else { return }
        let remaining = queue.filter { message in
            guard let outboxId = message.outboxId else { return true }
            return !confirmed.contains(outboxId)
        }
        guard remaining.count != queue.count else { return }
        pendingMessages[sessionId] = remaining
    }

    /// The pending-send bubbles to show for a session, oldest first: the server's own queue,
    /// then this device's own not-yet-confirmed sends.
    ///
    /// While any local bubble is still nameless (no `outboxId` — its send request has not
    /// answered yet), the server's list is held back entirely. Without that, the two would draw
    /// the same message twice for as long as the request is in flight, since a status event
    /// produced before the request answers cannot yet know about it.
    public func pendingBubbleTexts(sessionId: String) -> [String] {
        let localPending = pendingMessages[sessionId] ?? []
        let localOutboxIds = Set(localPending.compactMap(\.outboxId))
        let confirmedOutboxIds = Set((messages[sessionId] ?? []).compactMap(\.outboxId))
        let bridging = localPending.contains { $0.outboxId == nil }

        let serverPending: [String] =
            bridging
            ? []
            : delivery(for: sessionId).pendingSends
                .filter { !localOutboxIds.contains($0.id) && !confirmedOutboxIds.contains($0.id) }
                .map(\.text)

        return serverPending + localPending.map(\.text)
    }
}

extension Message {
    /// A transcript row for a send that has left this device but has no entry of its own yet —
    /// the bubble the web has always drawn at the tail of the conversation while a message is in
    /// the queue (`ChatView.tsx`, `data-pending-bubble`).
    ///
    /// A synthesised `Message` rather than a row kind of its own, so it flows through the single
    /// measured layout every other row uses: `TranscriptRowPlan` routes it to a `.userBubble`
    /// exactly like something Freddy typed, and it gets a real measured height rather than an
    /// estimate. The `scrolling` skill's central rule is what makes that the only acceptable
    /// shape here — a bubble whose height nobody measured moves every row above it when the send
    /// lands and it is replaced by the real entry.
    ///
    /// Ids are negative because the server's never are, so a bubble can never collide with a real
    /// row in the anchoring arithmetic that keys on row id.
    public static func pendingBubble(sessionId: String, index: Int, text: String) -> Message {
        Message(
            id: -(index + 1), sessionId: sessionId, type: .user, subtype: nil, outboxId: nil, timestamp: nil,
            content: text, thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil, tokens: nil,
            origin: nil, originMeta: nil, createdAt: nil)
    }

    /// Whether this row is one of the synthesised bubbles above, rather than something the server
    /// has actually recorded.
    public var isPendingBubble: Bool { id < 0 }
}
