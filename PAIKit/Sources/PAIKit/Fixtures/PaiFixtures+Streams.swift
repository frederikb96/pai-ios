#if DEBUG

    import Foundation

    extension PaiFixtures {

        /// The transcript stream, as a complete `text/event-stream` body.
        ///
        /// A fixture answers a request once and finishes, so the stream ends after these events
        /// rather than staying open — the client then treats it as a dropped connection and
        /// reconnects on its backoff. That is the right behaviour to leave in place: the messages
        /// have already arrived and been rendered, which is what a screenshot needs, and a
        /// reconnect loop against a fixture is harmless and self-limiting.
        ///
        /// The transcript arrives here as well as over REST because a screen that renders only
        /// what the stream delivered would photograph empty otherwise, and the point of fixture
        /// mode is that every screen has content.
        /// An SSE `data:` field is one line. A pretty-printed JSON body interpolated straight in
        /// produces lines that carry no `data:` prefix at all, so the framing silently ends after
        /// the first one and the payload decodes as truncated garbage — which is why every body
        /// here is flattened onto a single line first.
        private static func event(_ name: String, _ json: String) -> String {
            "event: \(name)\ndata: \(json.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " "))\n\n"
        }

        public static let sseStream: String =
            event("init", #"{"entries": \#(transcript), "cursor": 9060, "has_more": false, "session_tokens": 48210}"#)
            + event("status", #"{"status": "ready", "working": true, "pending_sends": []}"#)
            + event("ping", "{}")

        /// The terminal stream, as a complete `text/event-stream` body.
        ///
        /// Each frame is one `frame` event carrying a whole pre-laid-out screen — the agent
        /// prepends a reset to every capture, so there is no cursor addressing to honour.
        public static let terminalStream: String = terminalFrames.map { event("frame", $0) }.joined()
    }

#endif
