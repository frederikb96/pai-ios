import Foundation

/// What a Bash call changed on disk, as Claude Code recorded it: stored on the tool result under
/// `bash_edit_diff`, with Claude Code's own field names kept as they are.
///
/// Decoding is strict on the fields a diff cannot be drawn without and lenient on the optional
/// flags. ``ToolResult`` drops the whole value when it does not decode, so a shape this build does
/// not understand reads as no diff at all rather than as a transcript that failed to load.
public struct BashEditDiff: Codable, Sendable, Equatable {
    public let files: [BashEditDiffFile]
    /// Files that changed and carry no diff here, on top of ``files``.
    public let moreFiles: Int
    public let changedFiles: [String]?
    /// Part of the diff could not be taken: an oversized or unreadable file, a git failure.
    public let unavailable: Bool
    /// Another Bash call ran in the same repository at the same time, so some changes may be its.
    public let shared: Bool
    /// A command that moves the whole tree, for which no diff is taken.
    public let skipped: Bool

    enum CodingKeys: String, CodingKey {
        case files, moreFiles, changedFiles, unavailable, shared, skipped
    }

    public init(
        files: [BashEditDiffFile], moreFiles: Int = 0, changedFiles: [String]? = nil, unavailable: Bool = false,
        shared: Bool = false, skipped: Bool = false
    ) {
        self.files = files
        self.moreFiles = moreFiles
        self.changedFiles = changedFiles
        self.unavailable = unavailable
        self.shared = shared
        self.skipped = skipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = try container.decode([BashEditDiffFile].self, forKey: .files)
        moreFiles = try container.decodeIfPresent(Int.self, forKey: .moreFiles) ?? 0
        changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles)
        unavailable = try container.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
        shared = try container.decodeIfPresent(Bool.self, forKey: .shared) ?? false
        skipped = try container.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
    }
}

public struct BashEditDiffFile: Codable, Sendable, Equatable {
    public let filePath: String
    public let hunks: [BashEditDiffHunk]
    public let created: Bool?
    public let deleted: Bool?

    public init(filePath: String, hunks: [BashEditDiffHunk], created: Bool? = nil, deleted: Bool? = nil) {
        self.filePath = filePath
        self.hunks = hunks
        self.created = created
        self.deleted = deleted
    }
}

public struct BashEditDiffHunk: Codable, Sendable, Equatable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    /// Each line led by `+`, `-` or a space, or by `\` for git's "no newline" remark.
    public let lines: [String]

    enum CodingKeys: String, CodingKey {
        case oldStart, oldLines, newStart, newLines, lines
    }

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [String]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        oldStart = try container.decode(Int.self, forKey: .oldStart)
        oldLines = try container.decode(Int.self, forKey: .oldLines)
        newStart = try container.decode(Int.self, forKey: .newStart)
        newLines = try container.decode(Int.self, forKey: .newLines)
        lines = try container.decode([String].self, forKey: .lines)
        guard lines.allSatisfy({ line in line.first.map { "+- \\".contains($0) } ?? false }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lines, in: container, debugDescription: "A diff line has no recognised prefix")
        }
    }
}
