import PAIKit
import SwiftUI

/// The slim row above a composer's text field naming the skills the prompt mentions: the leading
/// chain (what runs) in the accent colour, later mentions plain, and an amber chip for a token
/// that is one typo away from a real skill, which corrects the token when tapped.
///
/// What the chips say is `SkillComposer`'s decision; this only draws it. Nothing is drawn for an
/// empty list, so a prompt without skills costs no height.
struct SkillMentionRow: View {
    let items: [SkillComposer.RowItem]
    let onFix: (SkillComposer.RowItem) -> Void

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        chip(item)
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
