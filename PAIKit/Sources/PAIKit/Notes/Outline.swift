import Foundation

/// One heading, with its Character offset into the body so a jump can go straight there rather
/// than merely scrolling by heading index.
public struct OutlineEntry: Equatable, Sendable, Identifiable {
    public let level: Int
    public let text: String
    public let offset: Int

    public var id: Int { offset }
}

/// ATX-style markdown headings only (`# `..`###### `) — the toolbar this app's editor offers
/// never produces setext (`===`/`---`) headings, so parsing for them would find headings the
/// editor itself cannot create.
public func parseOutline(_ body: String) -> [OutlineEntry] {
    // Declared locally rather than as a top-level `let`: `Regex` is not `Sendable`, so a shared
    // global fails Swift 6 strict concurrency — see the `ios` skill's own note on this trap.
    let headingPattern = /^(#{1,6})\s+(.+?)\s*$/
    var entries: [OutlineEntry] = []
    var offset = 0
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        if let match = try? headingPattern.firstMatch(in: line) {
            entries.append(OutlineEntry(level: match.output.1.count, text: String(match.output.2), offset: offset))
        }
        offset += line.count + 1
    }
    return entries
}
