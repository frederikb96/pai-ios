import Foundation
import PAIKit

/// Where a wake-word take's WAV waits on this phone until the backend has it — Application
/// Support, beside the past recordings. Nothing stays here once uploaded: the backend is the
/// corpus's one home.
struct WakeWordSampleFiles: WakeWordTakeFiles {
    private let directory: URL

    init(fileManager: FileManager = .default) {
        let base =
            (try? fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? fileManager.temporaryDirectory
        directory = base.appendingPathComponent("WakeWordSamples", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    func read(fileName: String) -> Data? {
        try? Data(contentsOf: url(fileName: fileName))
    }

    func delete(fileName: String) {
        try? FileManager.default.removeItem(at: url(fileName: fileName))
    }
}
