import Foundation
import PAIKit

/// The app's one `VoiceDiagnosticsLog`, backed by a sandboxed Application Support directory —
/// present in every build including release, so a device test that goes wrong on a phone Freddy
/// is actually holding leaves something to read afterwards, not just a debugger nobody attached.
enum AppVoiceDiagnosticsLog {
    static let shared: VoiceDiagnosticsLog = {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return VoiceDiagnosticsLog(directory: base.appendingPathComponent("VoiceDiagnostics", isDirectory: true))
    }()

    /// Flushes the pending in-memory lines to disk on a slow, steady cadence — cheap enough to
    /// leave running for the app's whole lifetime, and frequent enough that a crash loses at most
    /// a few seconds of lines. Call once, from app startup; a second call just runs a second,
    /// redundant loop against the same thread-safe store.
    static func startPeriodicFlush() {
        Task(priority: .background) {
            while !Task.isCancelled {
                shared.flush()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The log's current bytes, staged as a file ready to attach to a session or hand to the share
    /// sheet — the one place both surfaces build this from, so the filename and mime type agree.
    static func makeAttachment() -> StagedAttachment {
        let iso = ISO8601DateFormatter().string(from: Date())
        let data = shared.exportData()
        return StagedAttachment(
            filename: "voice-diagnostics-\(iso).log", mimeType: "text/plain", data: data, previewImage: nil,
            originalSize: data.count)
    }
}
