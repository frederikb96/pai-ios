import Foundation
import Observation

/// Where the upload queue sends things — `PaiApiClient` in the app, a fake in tests.
public protocol WakeWordUploadTransport: Sendable {
    func putRun(id: String, run: WakeWordRunUpload) async throws
    func putTake(runId: String, take: WakeWordPendingTake, wav: Data) async throws -> WakeWordTakeUploadOutcome
}

/// Where a pending take's WAV lives on this phone until the backend has it.
public protocol WakeWordTakeFiles: Sendable {
    func read(fileName: String) -> Data?
    func delete(fileName: String)
}

/// A run as this phone holds it until every take has reached the backend.
public struct PendingWakeWordRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let upload: WakeWordRunUpload
    /// The backend has the run itself, so its takes can follow.
    public var runStored: Bool
    /// Takes recorded and not yet stored on the backend, oldest first.
    public var takes: [WakeWordPendingTake]
    /// Still recording — more takes may follow, so an empty `takes` does not finish it.
    public var isOpen: Bool
}

/// Gets wake-word sample runs to the backend whatever the network is doing: a run is queued the
/// moment it starts, each take the moment it closes, and the queue drains whenever it is asked —
/// on a take closing, the app coming to the foreground, the network path returning. What is
/// queued survives the app being killed.
///
/// Order is the contract the backend holds it to: a run is stored before any of its takes, and a
/// take answered "run gone" (deleted on the web meanwhile) drops the whole run here too, audio
/// included, rather than retrying into a run that no longer exists. A take the backend refuses
/// outright (a 4xx that is not about credentials or load) is dropped alone and reported to `log`,
/// since sending it again can only be refused again and would block every take behind it.
@MainActor
@Observable
public final class WakeWordUploadQueue {
    public private(set) var runs: [PendingWakeWordRun]
    /// What the last failed drain said, cleared by the next one that gets through.
    public private(set) var lastError: String?

    private static let storageKey = "wakeWordUploadQueue"
    private let storage: SettingsKeyValueStore
    private let transport: WakeWordUploadTransport
    private let files: WakeWordTakeFiles
    private let log: @Sendable (String) -> Void
    private var isDraining = false
    private var drainRequestedWhileDraining = false

    public init(
        storage: SettingsKeyValueStore, transport: WakeWordUploadTransport, files: WakeWordTakeFiles,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.storage = storage
        self.transport = transport
        self.files = files
        self.log = log
        runs = storage.value(forKey: Self.storageKey) ?? []
    }

    public func openRun(id: String, upload: WakeWordRunUpload) {
        guard !runs.contains(where: { $0.id == id }) else { return }
        runs.append(PendingWakeWordRun(id: id, upload: upload, runStored: false, takes: [], isOpen: true))
        persist()
    }

    public func addTake(runId: String, take: WakeWordPendingTake) {
        guard let index = runs.firstIndex(where: { $0.id == runId }) else {
            files.delete(fileName: take.fileName)
            return
        }
        runs[index].takes.append(take)
        persist()
    }

    public func closeRun(id: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[index].isOpen = false
        persist()
    }

    /// Forgets a run that has not fully reached the backend yet, deleting its audio here. A run
    /// the backend already holds is deleted there, by the caller.
    public func removeRun(id: String) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        for take in runs[index].takes { files.delete(fileName: take.fileName) }
        runs.remove(at: index)
        persist()
    }

    /// Sends whatever is queued, in order, stopping at the first failure so nothing is attempted
    /// out of order; the next drain picks up from there. A drain asked for while one is running
    /// runs again once it finishes, so a take closed mid-drain is never left waiting for the next
    /// trigger.
    public func drain() async {
        guard !isDraining else {
            drainRequestedWhileDraining = true
            return
        }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainRequestedWhileDraining = false
            await drainOnce()
        } while drainRequestedWhileDraining
    }

    private func drainOnce() async {
        for runId in runs.map(\.id) {
            guard let run = runs.first(where: { $0.id == runId }) else { continue }
            if !run.runStored {
                do {
                    try await transport.putRun(id: run.id, run: run.upload)
                } catch {
                    lastError = "\(error)"
                    return
                }
                update(runId) { $0.runStored = true }
            }
            while let take = runs.first(where: { $0.id == runId })?.takes.first {
                guard let wav = files.read(fileName: take.fileName) else {
                    update(runId) { $0.takes.removeAll { $0.id == take.id } }
                    continue
                }
                let outcome: WakeWordTakeUploadOutcome
                do {
                    outcome = try await transport.putTake(runId: runId, take: take, wav: wav)
                } catch let error as PaiError where error.isPermanentRejection {
                    log("wake-word take \(take.id) of run \(runId) refused, dropped: \(error.userMessage)")
                    files.delete(fileName: take.fileName)
                    update(runId) { $0.takes.removeAll { $0.id == take.id } }
                    continue
                } catch {
                    lastError = "\(error)"
                    return
                }
                switch outcome {
                case .stored:
                    files.delete(fileName: take.fileName)
                    update(runId) { $0.takes.removeAll { $0.id == take.id } }
                case .runGone:
                    removeRun(id: runId)
                }
            }
            if let finished = runs.first(where: { $0.id == runId }), !finished.isOpen, finished.takes.isEmpty {
                runs.removeAll { $0.id == runId }
                persist()
            }
        }
        lastError = nil
    }

    private func update(_ runId: String, _ change: (inout PendingWakeWordRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == runId }) else { return }
        change(&runs[index])
        persist()
    }

    private func persist() {
        storage.setValue(runs, forKey: Self.storageKey)
    }
}
