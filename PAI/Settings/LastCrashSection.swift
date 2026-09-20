import PAIKit
import SwiftUI
import UIKit

/// The captured crash launch already presented once — kept here so it can be reread or deleted
/// without interrupting every launch.
struct LastCrashSection: View {
    @State private var record: CrashRecord?
    @State private var showing: CrashRecord?

    var body: some View {
        Section("Last Crash") {
            if let record {
                Button("View Crash Report") { showing = record }
                    .accessibilityIdentifier("view-last-crash")
                Button("Delete Crash Report", role: .destructive) {
                    CrashReporter.clearLast()
                    self.record = nil
                }
                .accessibilityIdentifier("delete-last-crash")
            } else {
                Text("No crash captured.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .onAppear { record = CrashReporter.readLast() }
        .sheet(item: $showing) { crash in
            CrashReportSheet(record: crash)
        }
    }
}
