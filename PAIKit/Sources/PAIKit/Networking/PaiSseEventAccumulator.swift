import Foundation

/// Accumulates `event:`/`data:` lines into complete SSE records, framed by a blank line —
/// pulled out of `PaiSseClient`'s connection loop specifically so the framing rules can be
/// exercised on the free Linux runner. `PaiSseClient` itself cannot build there
/// (`URLSession.bytes(for:)` is Apple-only, see `Package.swift`); this type touches neither
/// `URLSession` nor anything else Apple-only, so it stays on every platform while the transport
/// around it does not.
struct SseEventAccumulator: Sendable, Equatable {
    private var eventName: String?
    private var dataLines: [String] = []

    /// Feeds one line of a `text/event-stream` body. Returns the completed `(name, data)`
    /// record the moment a blank line terminates it; returns `nil` while a record is still
    /// accumulating, including when the blank line arrives with no event name or no data
    /// lines — an incomplete record is discarded, not emitted, matching the original inline
    /// loop's `guard let name = eventName, !dataLines.isEmpty`.
    mutating func ingest(line: String) -> (name: String, data: String)? {
        if line.isEmpty {
            defer {
                eventName = nil
                dataLines = []
            }
            guard let name = eventName, !dataLines.isEmpty else { return nil }
            return (name, dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix("event:") {
            eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            dataLines.append(Self.sseDataValue(from: line.dropFirst("data:".count)))
        }
        // Any other field (id:, retry:, comments) goes unused by this stream, same as the web client.
        return nil
    }

    /// Per the SSE spec, at most one leading space after `data:` is stripped — the rest of the
    /// line, including any other leading or trailing whitespace, is data. `.trimmingCharacters`
    /// over-strips; JSON payloads survive that by luck (whitespace outside string literals is
    /// insignificant), but it is wrong on principle for a framing rule that events beyond JSON
    /// can carry through this same parser. `PaiSseClient` re-exposes this under its own name so
    /// existing call sites and tests keep working; the logic lives here, once.
    static func sseDataValue(from line: Substring) -> String {
        line.first == " " ? String(line.dropFirst()) : String(line)
    }
}
