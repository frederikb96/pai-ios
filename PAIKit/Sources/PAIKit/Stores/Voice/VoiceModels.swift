import Foundation

/// Why a recording ended — mirrors the web's `RecordingEnd` union (`useVoiceRecording.ts`),
/// which every saved recording's metadata and every UI message keys off.
public enum RecordingEndReason: String, Sendable, Equatable, Codable {
    case user
    case silence
    case interrupted
    case error
    case connectionLost = "connection-lost"
}

/// The recording's lifecycle. `.connecting` covers everything between the user's tap and the
/// realtime socket actually accepting audio — token mint, transport connect, waiting for
/// `session_started` — so the UI has one spinner state for all of it rather than several.
public enum VoiceRecordingState: Sendable, Equatable {
    case idle
    case connecting
    case recording
    case stopping
}

/// Distinct answers to "why can't I record right now". Collapsing these into one generic error
/// is exactly the failure mode the spec calls out: a missing key, an unreachable ElevenLabs, and
/// an unauthorized caller are three different problems with three different fixes, and reporting
/// them identically leaves the user unable to tell which one they hit.
public enum VoiceStartFailure: Error, Sendable, Equatable {
    /// 503 from `/api/voice/token` — no ElevenLabs key set server-side, or it cannot be
    /// decrypted with the configured keys.
    case keyNotConfigured
    /// 502 — ElevenLabs rejected the mint or was unreachable. Carries the backend's detail text
    /// when it supplied one.
    case serviceUnavailable(String?)
    /// 403 — the caller is not an owner identity.
    case notPermitted
    /// Anything else the mint can fail with: a transport error, a decode failure, a status code
    /// the contract does not document.
    case other(PaiError)
}

extension VoiceStartFailure {
    /// Classifies whatever `PaiApiClient.mintVoiceToken` threw. A non-`PaiError` (a
    /// `CancellationError`, say) falls into `.other` rather than being force-cast, since a mint
    /// failing in a way this contract never documented is still a real failure to report.
    public static func classify(_ error: Error) -> VoiceStartFailure {
        guard let paiError = error as? PaiError else {
            return .other(.transport("\(error)"))
        }
        switch paiError {
        case let .detail(text, statusCode):
            return classify(statusCode: statusCode, detail: text, fallback: paiError)
        case let .http(statusCode, _):
            return classify(statusCode: statusCode, detail: nil, fallback: paiError)
        case .transport, .decoding:
            return .other(paiError)
        }
    }

    private static func classify(statusCode: Int, detail: String?, fallback: PaiError) -> VoiceStartFailure {
        switch statusCode {
        case 503: return .keyNotConfigured
        case 502: return .serviceUnavailable(detail)
        case 403: return .notPermitted
        default: return .other(fallback)
        }
    }
}

/// Client-local voice preferences — the web keeps these in `localStorage`, iOS in
/// `UserDefaults`; this is the value type either side reads and writes, with the web's own
/// defaults (`stores/settings.ts`).
public struct VoiceSettings: Sendable, Equatable {
    public enum Language: String, Sendable, Equatable, Codable {
        case auto, en, de
    }

    public var sttLanguage: Language
    /// `''` means the system default input — never a real device identifier, so it is always
    /// safe to persist even when no device is currently selected.
    public var micDeviceId: String
    public var silenceDetectionEnabled: Bool
    public var silenceThreshold: Double
    public var silenceDurationMs: Int

    public init(
        sttLanguage: Language = .auto,
        micDeviceId: String = "",
        silenceDetectionEnabled: Bool = false,
        silenceThreshold: Double = 0.005,
        silenceDurationMs: Int = 3000
    ) {
        self.sttLanguage = sttLanguage
        self.micDeviceId = micDeviceId
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.silenceThreshold = silenceThreshold
        self.silenceDurationMs = silenceDurationMs
    }
}
