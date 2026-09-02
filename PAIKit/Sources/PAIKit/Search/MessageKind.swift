import Foundation

/// A kind of transcript message Freddy can step between — the same stepping the search bar
/// already gives free text, chosen from a picker folded into that same control.
///
/// The predicates themselves live server-side (`_kind_predicate` in
/// `backend/src/pai_cloud/repository.py`) — `findMessages(kind:)` is what the picker calls, and
/// this type keeps only the UI strings, so the matching rules exist exactly once
/// (search-virtualization design, decision 5). No Swift predicate decides what kind a message
/// is; a `MessageKind` here only ever labels an id the server already picked.
///
/// `.boundary` folds session start and every compaction marker into ONE kind on purpose
/// (Freddy's own spec): stepping through it visits "where this conversation began" and every
/// point it was later compacted, rather than making him pick between two near-identical concepts.
public enum MessageKind: String, CaseIterable, Sendable, Equatable {
    case freddy
    case kai
    case notification
    case boundary
    case agentInvocation = "agent_invocation"

    public var label: String {
        switch self {
        case .freddy: "Your messages"
        case .kai: "Kai's replies"
        case .notification: "Push notifications"
        case .boundary: "Session start & compaction"
        case .agentInvocation: "Agent invocations"
        }
    }
}
