import Foundation
import Observation

/// The backend's debug recordings — what each engine actually received, newest first — and the
/// switch that keeps them. Refreshed on open and on demand; nothing here polls.
@MainActor
@Observable
public final class DebugRecordingsStore {
    public private(set) var recordings: [DebugRecording] = []
    /// `nil` until the first load answers.
    public private(set) var enabled: Bool?
    public private(set) var isLoading = false
    public private(set) var error: String?

    private let apiClient: PaiApiClient

    public init(apiClient: PaiApiClient) {
        self.apiClient = apiClient
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await apiClient.listDebugRecordings()
            recordings = list.recordings
            enabled = list.enabled
            error = nil
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    /// Removed from the list only once the backend confirms — a recording still being written
    /// is refused there, and must stay listed rather than vanish until the next refresh.
    public func delete(id: String) async {
        do {
            try await apiClient.deleteDebugRecording(id: id)
            recordings.removeAll { $0.id == id }
            error = nil
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func setEnabled(_ enabled: Bool) async {
        do {
            let settings = try await apiClient.setDebugRecordingsEnabled(enabled)
            self.enabled = settings.debugRecordingsEnabled
            error = nil
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    public func audio(for id: String) async throws -> Data {
        try await apiClient.getDebugRecordingAudio(id: id)
    }
}
