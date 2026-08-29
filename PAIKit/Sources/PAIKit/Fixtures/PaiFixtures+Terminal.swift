import Foundation

/// The terminal SSE stream (`GET /api/session/{id}/terminal`, `docs/ARCHITECTURE.md` "Terminal
/// streaming"). Each element is one `frame` event's payload, in arrival order, ready for a
/// fixture-mode stream to hand out one at a time.
///
/// ⚠️ **`types.ts`'s `TerminalFrameEvent` is stale.** It declares only `{ data: string }`, but
/// `web/src/api/terminalStream.ts` (and `docs/ARCHITECTURE.md`, "Scrollback") both read a `live`
/// boolean off the same payload — "Absent/malformed `live` defaults to `true`" is a direct quote
/// from that client. The wire shape below is `{data, live}`, verified against the web client's
/// own parsing rather than the incomplete type; the last frame omits `live` on purpose, to
/// exercise that exact fallback.
extension PaiFixtures {

    /// Five frames: a live prompt, an echoed command, ANSI-coloured output, a scrolled-back frame
    /// (`live: false` — the only signal the "scrolled back" banner has), and one with `live`
    /// missing entirely.
    public static let terminalFrames: [String] = [
        #"""
        { "data": "\u001b[32mfreddy@vm\u001b[0m:\u001b[34m~/wt/pai-ios-fixtures\u001b[0m$ ", "live": true }
        """#,
        #"""
        { "data": "swift test --package-path PAIKit --skip-build\r\n", "live": true }
        """#,
        #"""
        { "data": "\u001b[32mTest Suite 'All tests' passed\u001b[0m at 2026-08-29 09:41:58.\r\n\t Executed 96 tests, with 0 failures\r\n", "live": true }
        """#,
        #"""
        { "data": "\u001b[33m--- scrolled back 40 lines ---\u001b[0m\r\nswift build --package-path PAIKit --build-tests\r\n", "live": false }
        """#,
        #"""
        { "data": "\u001b[32mfreddy@vm\u001b[0m:\u001b[34m~/wt/pai-ios-fixtures\u001b[0m$ " }
        """#,
    ]
}
