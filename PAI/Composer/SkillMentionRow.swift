import PAIKit
import SwiftUI

/// The slim row above a composer's text field naming the skills the prompt mentions: the leading
/// chain (what runs) in the accent colour, later mentions plain, and an amber chip for a token
/// that is one typo away from a real skill, which corrects the token when tapped. Claude Code
/// keywords the prompt carries follow as purple chips with a spark, and a built-in command the prompt starts
/// with (`/compact`) gets its own chip, marked as running like a leading skill.
///
/// What the chips say is `SkillComposer`'s decision; this only draws it. Nothing is drawn for an
/// empty list, so a prompt without skills or keywords costs no height.
struct SkillMentionRow: View {
    let items: [SkillComposer.RowItem]
    var keywords: [String] = []
    var builtinCommand: String?
    let onFix: (SkillComposer.RowItem) -> Void

    var body: some View {
        if !items.isEmpty || !keywords.isEmpty || builtinCommand != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let builtinCommand {
                        chipLabel(
                            "\u{25B6} /\(builtinCommand)", foreground: PaiPalette.Semantic.accentText,
                            background: PaiPalette.Semantic.accentBackground
                        )
                        .accessibilityLabel("Command /\(builtinCommand): Claude Code runs it when the message is sent")
                        .accessibilityIdentifier("builtin-command")
                    }
                    ForEach(items) { item in
                        chip(item)
                    }
                    ForEach(keywords, id: \.self) { word in
                        keywordChip(word)
                            .accessibilityLabel("Keyword \(word): Claude Code acts on it in the next prompt")
                            .accessibilityIdentifier("prompt-keyword")
                    }
                }
                .padding(.horizontal, 4)
            }
            .accessibilityIdentifier("skill-mention-row")
        }
    }

    @ViewBuilder
    private func chip(_ item: SkillComposer.RowItem) -> some View {
        if item.isFix {
            Button {
                onFix(item)
            } label: {
                chipLabel(
                    item.label, foreground: PaiPalette.Semantic.warningText,
                    background: PaiPalette.Semantic.warningBackground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Replace \(item.token) with \(item.name)")
        } else if item.kind == .runs {
            chipLabel(
                item.label, foreground: PaiPalette.Semantic.accentText, background: PaiPalette.Semantic.accentBackground
            )
        } else {
            chipLabel(
                item.label, foreground: PaiPalette.Semantic.textSecondary, background: PaiPalette.Semantic.raisedSurface
            )
        }
    }

    /// Claude Code's own words, purple with a spark so they are never read as a skill — a
    /// misspelling draws no chip at all, which is how it is noticed. The system purple follows
    /// the appearance, like the web's violet pair.
    private func keywordChip(_ word: String) -> some View {
        Label(word, systemImage: "sparkles")
            .labelStyle(.titleAndIcon)
            .font(PaiTypography.caption.font)
            .foregroundStyle(Color.purple)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15))
            .clipShape(Capsule())
    }

    private func chipLabel(_ text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(PaiTypography.caption.font)
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(Capsule())
    }
}
