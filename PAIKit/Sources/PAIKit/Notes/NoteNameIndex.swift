import Foundation

/// name (lowercased) -> id, for resolving `[[wikilinks]]` against the loaded index. A name
/// collision keeps whichever note the loop reaches last — the same ambiguity the backend's own
/// `ambiguous_names` reports, resolved the same arbitrary way rather than picked to agree with
/// it, since which one wins is not observable from this index alone.
public func buildNameToId(_ notes: [NoteSummary]) -> [String: String] {
    var map: [String: String] = [:]
    for note in notes { map[note.name.lowercased()] = note.id }
    return map
}
