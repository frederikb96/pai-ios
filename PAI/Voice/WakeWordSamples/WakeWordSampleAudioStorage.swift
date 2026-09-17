import Foundation

/// Where a wake-word sample take's WAV bytes live on disk — `PAIKit`'s `WakeWordSampleStore` owns
/// the metadata list; this owns only the bytes, the same split `FileRecordingAudioStorage`/
/// `RecordingAudioLibrary` already use for Past Recordings.
///
/// One directory, addressed by filename rather than by id — `WakeWordSample.fileName` is already
/// unique (`WakeWordSampleNaming`), so there is no separate id-to-path mapping to keep in sync
/// with it.
struct WakeWordSampleAudioStorage {
    private let directory: URL

    init(fileManager: FileManager = .default) {
        let base =
            (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("WakeWordSamples", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Same reasoning as `FileRecordingAudioStorage`'s identical block: this data has no
        // server copy at all, so a device backup is the only redundancy it ever gets.
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = false
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(resource)
    }

    func url(fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(fileName: fileName))
    }

    func load(fileName: String) -> Data? {
        try? Data(contentsOf: url(fileName: fileName))
    }

    /// The bytes every kept sample currently occupies — what the sample screen's storage line
    /// reports, mirroring `FileRecordingAudioStorage.totalBytesUsed()`.
    func totalBytesUsed() -> Int64 {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return entries.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }
}
