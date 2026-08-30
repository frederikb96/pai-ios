import Foundation

/// One captured crash. Kept separate from the capture mechanism below so its shape and encoding
/// are provable on the free Linux runner — an ObjC exception handler is not something Linux CI
/// can exercise, but the record it produces is worth being certain about regardless.
public struct CrashRecord: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let reason: String?
    public let callStack: [String]
    public let capturedAt: Date

    /// A capture is unique enough by when it happened — `.sheet(item:)` needs an id, and nothing
    /// here is worth a synthetic one.
    public var id: Date { capturedAt }

    public init(name: String, reason: String?, callStack: [String], capturedAt: Date) {
        self.name = name
        self.reason = reason
        self.callStack = callStack
        self.capturedAt = capturedAt
    }
}

// `NSException`/`NSSetUncaughtExceptionHandler` are Objective-C runtime facilities that
// swift-corelibs-foundation does not implement on Linux — guarded the same way `PaiPalette.swift`
// and `DebugBridge.swift` guard their own Apple-only imports, rather than excluded at the
// `Package.swift` level: the type still exists (empty) on Linux, so nothing referencing
// `CrashRecord` alone needs its own guard.
#if canImport(ObjectiveC)

    import ObjectiveC

    /// Persists what Apple's own crash report leaves out — the exception's name and reason
    /// string, not just symbolicated frames — to a file that survives the crash and is read back
    /// on the next launch. Exists because TestFlight's own crash report needs a tap on "Share
    /// with Developer" after relaunching to reach anyone at all, and even then carries no reason
    /// string for this class of crash; this captures automatically and needs nothing from whoever
    /// is holding the phone.
    ///
    /// `NSSetUncaughtExceptionHandler` catches Objective-C exceptions specifically — which
    /// `_Bug_Detected_In_Client_Of_UICollectionView_Invalid_Batch_Updates:` is one of, not a POSIX
    /// signal. It does not catch a Swift trap or a segfault; Apple's own symbolicated report
    /// already covers those reasonably well, and this exists for the gap in that report, not to
    /// replace it.
    public enum CrashReporter {
        private static let fileName = "last-crash.json"

        private static var fileURL: URL? {
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appendingPathComponent(fileName)
        }

        /// Call once, as early as possible in app startup — before anything that could itself
        /// crash during launch.
        public static func install() {
            NSSetUncaughtExceptionHandler { exception in
                let record = CrashRecord(
                    name: exception.name.rawValue,
                    reason: exception.reason,
                    callStack: exception.callStackSymbols,
                    capturedAt: Date()
                )
                guard let url = fileURL, let data = try? JSONEncoder().encode(record) else { return }
                try? data.write(to: url, options: .atomic)
            }
        }

        /// Whatever crash was captured before this launch, if any — read-only, so both the
        /// in-app surface and the debug bridge's `/crash` route can ask independently without
        /// racing each other for who gets to see it. `clearLast()` is the explicit way to
        /// acknowledge it, matching `/logs`' own read/`clear` split.
        public static func readLast() -> CrashRecord? {
            guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(CrashRecord.self, from: data)
        }

        public static func clearLast() {
            guard let url = fileURL else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

#endif
