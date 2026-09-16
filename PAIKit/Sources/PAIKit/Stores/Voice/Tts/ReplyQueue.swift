import Foundation

/// The FIFO of assistant replies waiting to be spoken — pure data, no socket, no clock, so its
/// ordering, dedupe and skip behaviour are provable without a real TTS connection.
///
/// A reply already split into `SpeechText.sentences(of:)` at enqueue time rather than carrying
/// raw text: `sentencesSent` is then a plain index into a fixed array, and "what's left to say
/// after a TTS socket drop" (`Entry.remaining`) needs no re-splitting or heuristics to recover.
public struct ReplyQueue: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let messageId: Int
        public let sentences: [String]
        /// How many of `sentences` have already been handed to the transport on the current (or
        /// a since-dropped) context — advanced by `recordSentencesSent`, read by `remaining`.
        /// Not `private(set)`: that would scope the setter to `Entry`'s own declaration, not to
        /// `ReplyQueue`, which is exactly what needs to mutate it through `entries[0]`.
        public var sentencesSent: Int

        fileprivate init(messageId: Int, sentences: [String]) {
            self.messageId = messageId
            self.sentences = sentences
            self.sentencesSent = 0
        }

        /// What a fresh context should be sent — the whole reply the first time, or everything
        /// after the last sentence a dropped context actually got, once a reconnect opens a new
        /// one. A repeated sentence is the acceptable cost of that reconnect, never a lost one.
        public var remaining: [String] {
            Array(sentences.dropFirst(sentencesSent))
        }

        public var isFullySent: Bool {
            sentencesSent >= sentences.count
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var head: Entry? { entries.first }
    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }

    /// Appends a reply to the tail — "arriving while speaking → appended", the architecture's own
    /// wording. A reply with no sentences at all (blank after `SpeechText` stripped everything)
    /// is not enqueued; there is nothing to speak and nothing to skip.
    public mutating func enqueue(messageId: Int, sentences: [String]) {
        guard !sentences.isEmpty else { return }
        entries.append(Entry(messageId: messageId, sentences: sentences))
    }

    /// The transport has handed `count` more of the head's sentences to ElevenLabs — advances
    /// `sentencesSent`, clamped to the entry's own length so a caller can never overshoot it.
    public mutating func recordSentencesSent(_ count: Int = 1) {
        guard !entries.isEmpty else { return }
        entries[0].sentencesSent = min(entries[0].sentencesSent + count, entries[0].sentences.count)
    }

    /// "computer skip" — drops the head wherever it had gotten to and returns it, so the caller
    /// can close its wire context and flush whatever audio was already scheduled for it.
    @discardableResult
    public mutating func dropHead() -> Entry? {
        guard !entries.isEmpty else { return nil }
        return entries.removeFirst()
    }

    /// The head finished playing in full — the ordinary way a reply leaves the queue, distinct
    /// from `dropHead()` only in what it means, not in what it does.
    @discardableResult
    public mutating func completeHead() -> Entry? {
        dropHead()
    }
}
