import Foundation

/// Whether a message card starts expanded, keyed by one string per card type and stored as one
/// `[String: Bool]` — port of `pai-cloud/web/src/stores/settings.ts`'s `expandPreferences`.
///
/// **Every default is off.** The dictionary starts empty and `SettingsStore.isExpandEnabled`
/// reads a missing key as `false` — deliberately, so a fresh install renders every tool call and
/// system message collapsed instead of a wall of expanded output. Never add a case here that
/// defaults to `true`; there is nowhere for that to live.
///
/// This preference is read at render time by whichever card is on screen — the catalogue and
/// the key-derivation functions below live here because they are the one thing that must never
/// drift out of sync with what a card actually asks for, not because rendering itself belongs to
/// the Settings screen.
public enum ExpandPreferences {

    /// The bucket a tool call/result card falls into. Mirrors `getToolExpandKey` in
    /// `web/src/components/MessageBubble.tsx:219-232` — order matches the web's `EXPAND_GROUPS`
    /// so the two stay easy to compare by eye.
    public enum ToolFamily: String, CaseIterable, Sendable {
        case read, edit, bash, grep, glob, agent, websearch, skill, mcp, other

        var groupTitle: String {
            switch self {
            case .read: return "Read"
            case .edit: return "Edit / Write"
            case .bash: return "Bash"
            case .grep, .glob: return "Search (Grep / Glob)"
            case .agent: return "Agent"
            case .websearch: return "Web"
            case .skill: return "Skill"
            case .mcp: return "MCP"
            case .other: return "Other Tools"
            }
        }

        /// Only the Search group disambiguates within itself; every other group's title already
        /// says what its two items are.
        var labelPrefix: String {
            switch self {
            case .grep: return "Grep "
            case .glob: return "Glob "
            default: return ""
            }
        }
    }

    /// Every `subtype` string `backend/src/pai_cloud/parser.py` assigns, confirmed by grepping
    /// every literal `subtype="..."` the parser writes (14 matches) rather than trusting its own
    /// module docstring, which is stale — it omits `compact_summary` and describes several of
    /// these as `type=user`-only when the web's `SystemCard` reads all of them through the same
    /// `system_<subtype>` key regardless of `type`. **VERIFIED against pai-cloud source at
    /// `~/Programming/pai-cloud/backend/src/pai_cloud/parser.py`, 2026-08-29** — re-grep
    /// `subtype="[a-z_]*"` there before trusting this list after a parser change.
    ///
    /// `.other` is not a real subtype string — it is `getSystemExpandKey`'s fallback for a
    /// `nil` subtype (`web/src/components/MessageBubble.tsx:305-308`), reachable whenever a
    /// `type=system` message carries no subtype at all.
    ///
    /// 🚨 Three of these — `.scheduled`, `.paiMessage`, `.other` — have no toggle in the web's
    /// own `EXPAND_GROUPS`, so a card reading one of those three keys there always reads `false`
    /// with no way for Freddy to change it. Not reproduced here: every case below gets a toggle.
    public enum SystemSubtype: String, CaseIterable, Sendable {
        case skill, context, command
        case commandOutput = "command_output"
        case image, notification, hook, compact
        case compactSummary = "compact_summary"
        case duration, interrupt, scheduled
        case agentMessage = "agent_message"
        case paiMessage = "pai_message"
        case other

        var label: String {
            switch self {
            case .skill: return "Skill Content"
            case .context: return "Context"
            case .command: return "Command"
            case .commandOutput: return "Command Output"
            case .image: return "Image"
            case .notification: return "Notification"
            case .hook: return "Hook"
            case .compact: return "Compact"
            case .compactSummary: return "Compact Summary"
            case .duration: return "Duration"
            case .interrupt: return "Interrupt"
            case .scheduled: return "Scheduled"
            case .agentMessage: return "Agent Message"
            case .paiMessage: return "PAI Message"
            case .other: return "Other"
            }
        }
    }

    /// One toggle: the key a card looks up, and the label a settings row shows next to it.
    public struct Item: Sendable, Equatable {
        public let key: String
        public let label: String
    }

    public struct Group: Sendable, Equatable {
        public let title: String
        public let items: [Item]
    }

    /// The bucket `getToolExpandKey` assigns a tool name to — lowercase, then the same
    /// substring/prefix rules as the web (`MessageBubble.tsx:219-231`). Anything unrecognized
    /// falls into `.other`, which is what makes the catalogue exhaustive: a brand-new tool name
    /// always resolves to a key that already has a toggle.
    public static func toolFamily(forToolName name: String) -> ToolFamily {
        let lower = name.lowercased()
        if lower == "bash" { return .bash }
        if lower == "read" { return .read }
        if lower.contains("edit") || lower == "write" || lower == "multiedit" { return .edit }
        if lower == "grep" { return .grep }
        if lower == "glob" { return .glob }
        if lower.contains("agent") || lower == "task" { return .agent }
        if lower == "websearch" || lower == "webfetch" { return .websearch }
        if lower == "skill" { return .skill }
        if lower.hasPrefix("mcp__") { return .mcp }
        return .other
    }

    public static func toolExpandKey(toolName name: String, isResult: Bool) -> String {
        let suffix = isResult ? "_result" : "_call"
        return "\(toolFamily(forToolName: name).rawValue)\(suffix)"
    }

    /// A `nil` subtype is `.other`'s wire shape too (`SystemSubtype.other`'s raw value is
    /// `"other"`), so this never needs a separate branch for it.
    public static func systemExpandKey(subtype: String?) -> String {
        let resolved = subtype.flatMap(SystemSubtype.init(rawValue:)) ?? .other
        return "system_\(resolved.rawValue)"
    }

    /// Every toggle Settings can show, grouped for display — generated from `ToolFamily` and
    /// `SystemSubtype` rather than hand-listed, so a case added to either enum appears here
    /// automatically instead of silently becoming an unreachable preference.
    public static let catalogue: [Group] = {
        var groups: [Group] = []

        func append(title: String, item: Item) {
            if let last = groups.last, last.title == title {
                groups[groups.count - 1] = Group(title: title, items: last.items + [item])
            } else {
                groups.append(Group(title: title, items: [item]))
            }
        }

        for family in ToolFamily.allCases {
            let prefix = family.labelPrefix
            append(title: family.groupTitle, item: Item(key: "\(family.rawValue)_call", label: "\(prefix)Call"))
            append(
                title: family.groupTitle, item: Item(key: "\(family.rawValue)_result", label: "\(prefix)Result"))
        }

        for subtype in SystemSubtype.allCases {
            append(title: "System", item: Item(key: "system_\(subtype.rawValue)", label: subtype.label))
        }

        // Not derived from any family or subtype: `message.thinking` is its own field on an
        // assistant message, not a `subtype`, and there is exactly one of it
        // (`web/src/stores/settings.ts`'s `EXPAND_GROUPS`, group "Other").
        append(title: "Other", item: Item(key: "thinking", label: "Thinking"))

        return groups
    }()
}
