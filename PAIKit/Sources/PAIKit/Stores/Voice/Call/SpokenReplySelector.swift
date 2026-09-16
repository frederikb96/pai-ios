import Foundation

/// Which of the transcript's rows call mode speaks: an assistant reply, arrived after the call
/// started, not already spoken.
///
/// A `Message.type == .assistant` row is always `subtype == nil` on this backend — `agent_message`
/// is a `user`-type subtype for a prompt relayed here from another session, never something an
/// assistant row itself carries — so there is no equivalent "was this relayed, not really said in
/// this conversation" case to filter here the way there is on the user side. Nothing in this
/// selector reads `subtype` as a result; the fixture corpus's assistant rows are what proves it.
public enum SpokenReplySelector {

    /// `baseline` is the newest transcript id already on screen when call mode started (or when
    /// the reply stream reconnected) — the guard against the SSE `init` replay trap: without it,
    /// entering call mode, or any later reconnect, would read the whole visible transcript aloud
    /// again. `spoken` is every id already queued or spoken this call, so a batch that overlaps
    /// one already handled never double-speaks it.
    public static func isSpeakable(_ message: Message, baseline: Int, spoken: Set<Int>) -> Bool {
        guard message.type == .assistant, message.id > baseline, !spoken.contains(message.id) else {
            return false
        }
        let content = message.content ?? ""
        return !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Filters and orders a batch of newly-arrived messages into the ones call mode should speak,
    /// in id order — the shape a `ReplyFeed` batch or an SSE `init` fold hands to
    /// `SpeechOutputSession.enqueue`, one call per returned message.
    public static func speakable(from messages: [Message], baseline: Int, spoken: Set<Int>) -> [Message] {
        messages
            .filter { isSpeakable($0, baseline: baseline, spoken: spoken) }
            .sorted { $0.id < $1.id }
    }
}
