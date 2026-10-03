import Foundation

/// What a take upload came back as — a run deleted elsewhere (on the web, say) is an answer the
/// upload queue acts on, not an error to retry.
public enum WakeWordTakeUploadOutcome: Sendable, Equatable {
    case stored
    case runGone
}

extension PaiApiClient {

    // MARK: Debug recordings

    public func listDebugRecordings() async throws -> DebugRecordingList {
        try await send(path: "/api/voice/debug-recordings")
    }

    /// The recording as a WAV — the exact samples the engine received behind a plain header.
    /// Fetched as bytes because the route needs the bearer header a streaming player cannot send.
    public func getDebugRecordingAudio(id: String) async throws -> Data {
        try await sendPassingThrough(
            path: "/api/voice/debug-recordings/\(id)/audio", method: "GET", contentType: nil, passthrough: []
        ).body
    }

    public func deleteDebugRecording(id: String) async throws {
        try await sendDiscardingResponse(
            path: "/api/voice/debug-recordings/\(id)", method: "DELETE", body: nil, contentType: nil)
    }

    // MARK: Wake-word corpus

    public func listWakeWordRuns() async throws -> [WakeWordRun] {
        let list: WakeWordRunList = try await send(path: "/api/wake-word/runs")
        return list.runs
    }

    /// Creates the run, or updates it when it already exists — safe to repeat.
    public func putWakeWordRun(id: String, run: WakeWordRunUpload) async throws {
        let body: Data
        do {
            body = try JSONEncoder().encode(run)
        } catch {
            throw PaiError.decoding("\(error)")
        }
        try await sendDiscardingResponse(path: "/api/wake-word/runs/\(id)", method: "PUT", body: body)
    }

    public func putWakeWordTake(
        runId: String, takeId: String, wav: Data, index: Int, recordedAt: String, durationMs: Int
    ) async throws -> WakeWordTakeUploadOutcome {
        let boundary = "PAIKit-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"audio\"; filename=\"\(takeId).wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        Self.appendFormField(&body, boundary: boundary, name: "index", value: String(index))
        Self.appendFormField(&body, boundary: boundary, name: "recorded_at", value: recordedAt)
        Self.appendFormField(&body, boundary: boundary, name: "duration_ms", value: String(durationMs))
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let result = try await sendPassingThrough(
            path: "/api/wake-word/runs/\(runId)/takes/\(takeId)", method: "PUT", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", passthrough: [404]
        )
        return result.statusCode == 404 ? .runGone : .stored
    }

    public func deleteWakeWordRun(id: String) async throws {
        try await sendDiscardingResponse(
            path: "/api/wake-word/runs/\(id)", method: "DELETE", body: nil, contentType: nil)
    }

    public func deleteWakeWordTake(runId: String, takeId: String) async throws {
        try await sendDiscardingResponse(
            path: "/api/wake-word/runs/\(runId)/takes/\(takeId)", method: "DELETE", body: nil, contentType: nil)
    }

    public func getWakeWordTakeAudio(runId: String, takeId: String) async throws -> Data {
        try await sendPassingThrough(
            path: "/api/wake-word/runs/\(runId)/takes/\(takeId)/audio", method: "GET", contentType: nil,
            passthrough: []
        ).body
    }
}

extension PaiApiClient: WakeWordUploadTransport {
    public func putRun(id: String, run: WakeWordRunUpload) async throws {
        try await putWakeWordRun(id: id, run: run)
    }

    public func putTake(runId: String, take: WakeWordPendingTake, wav: Data) async throws -> WakeWordTakeUploadOutcome {
        try await putWakeWordTake(
            runId: runId, takeId: take.id, wav: wav, index: take.index, recordedAt: take.recordedAt,
            durationMs: take.durationMs)
    }
}
