import PAIKit
import SwiftUI

/// Shown automatically on the launch after an uncaught exception — no tap-through needed, unlike
/// TestFlight's own crash-report prompt, and it carries the exception's reason string, which
/// Apple's symbolicated report does not. `.textSelection(.enabled)` is the point: this exists so
/// the text can be copied out and reported, not just read on screen.
struct CrashReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let record: CrashRecord

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(record.name)
                        .font(.headline)
                    if let reason = record.reason {
                        Text(reason)
                            .font(.body)
                    }
                    if !record.callStack.isEmpty {
                        Text(record.callStack.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .textSelection(.enabled)
            .navigationTitle("Last Crash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("crash-report-sheet")
        }
    }
}
