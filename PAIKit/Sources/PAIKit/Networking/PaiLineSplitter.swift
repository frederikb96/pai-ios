import Foundation

/// Splits a raw byte stream into lines, preserving blank lines — unlike `bytes.lines`
/// (`AsyncLineSequence`), which silently skips them (a documented, longstanding gap: there is no
/// `omittingEmptySubsequences`-style option for `.lines`, unlike `String.split`). In
/// `text/event-stream`, a blank line is the record terminator; both `PaiSseClient` and
/// `PaiTerminalStreamClient` frame on exactly that, so a line source that drops it makes every
/// record un-terminated and no event is ever decoded.
///
/// Handles `\n`, `\r\n`, and a lone `\r` as line endings — `sse_starlette`, the backend this talks
/// to, defaults to `\r\n`. A `\r` at the very end of a chunk is held back rather than treated as a
/// terminator, since the next chunk may complete it into `\r\n`; the network can split a chunk
/// anywhere, including inside a two-byte terminator.
struct LineSplitter: Sendable, Equatable {
    private var buffer: [UInt8] = []

    /// Feeds one chunk of raw bytes, in whatever boundaries the network happened to deliver them
    /// (see `PaiHttpByteStream`), and returns every complete line the chunk finishes — zero, one,
    /// or several, in order. A line still accumulating stays buffered for the next call.
    mutating func ingest(_ data: Data) -> [String] {
        buffer.append(contentsOf: data)
        var lines: [String] = []
        var start = 0
        var i = 0
        while i < buffer.count {
            switch buffer[i] {
            case 0x0A:  // \n
                lines.append(decode(start..<i))
                i += 1
                start = i
            case 0x0D:  // \r — either \r\n or a lone \r
                guard i + 1 < buffer.count else {
                    // Last byte currently buffered; the next chunk might bring the \n that
                    // completes a \r\n terminator. Stop without consuming it.
                    i = buffer.count
                    break
                }
                let terminatorEnd = buffer[i + 1] == 0x0A ? i + 2 : i + 1
                lines.append(decode(start..<i))
                i = terminatorEnd
                start = i
            default:
                i += 1
            }
        }
        buffer.removeFirst(start)
        return lines
    }

    /// Flushes a trailing line left in the buffer when the connection ends without a final
    /// terminator — mirrors how a line reader treats end-of-stream as an implicit one. `nil` if
    /// nothing was pending.
    mutating func finish() -> String? {
        defer { buffer = [] }
        guard !buffer.isEmpty else { return nil }
        return decode(0..<buffer.count)
    }

    private func decode(_ range: Range<Int>) -> String {
        String(decoding: buffer[range], as: UTF8.self)
    }
}
