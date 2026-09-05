import PAIKit
import SwiftUI

/// A single report, full page — pushed from a row or block leader's own report chip
/// (`ArcBlockDetailView`'s `ArcReportChip`). Fetches by report uuid alone
/// (`GET /api/arc/reports/{uuid}`, which already carries the full content): self-sufficient, so
/// a navigation path restored after a relaunch needs nothing else about the spec to have loaded
/// first. Mirrors `ArcReportPage.tsx`; its header's back arrow is this screen's native back
/// button/swipe, both landing on the spec view for the same reason — see `Route.arcReport`'s
/// doc comment on why that is free here rather than needing a parallel `sessionOrigin` field.
struct ArcReportScreen: View {
    let specUuid: String
    let reportUuid: String

    @Environment(AppEnvironment.self) private var environment
    @State private var report: ArcReport?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let summary = report.summary, !summary.isEmpty {
                            Text(summary)
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.textMuted)
                        }
                        if let time = SessionTimeFormat.text(for: report.createdAt) {
                            Text(time)
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                        MarkdownContentView(blocks: MarkdownParser.parse(report.content))
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let errorMessage {
                centeredMessage(errorMessage, systemImage: "exclamationmark.triangle")
            } else {
                centeredMessage(nil, systemImage: nil)
            }
        }
        .paiScreenBackground()
        .navigationTitle(report?.name ?? "Report")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("arc-report-screen")
        .task {
            guard let client = environment.connection?.apiClient else { return }
            do {
                report = try await client.getArcReport(uuid: reportUuid)
            } catch {
                errorMessage = (error as? PaiError)?.userMessage ?? "Could not load this report"
            }
        }
    }

    private func centeredMessage(_ text: String?, systemImage: String?) -> some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            } else {
                ProgressView()
            }
            if let text {
                Text(text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
