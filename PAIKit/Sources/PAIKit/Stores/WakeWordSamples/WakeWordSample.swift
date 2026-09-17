import Foundation

/// One recorded take from the wake-word sample screen — a real utterance through a real
/// microphone, meant to be mixed into the synthetic-TTS corpus the offline "computer" classifier
/// (`PAI/Voice/WakeWordModels/computer.onnx`, `Tooling/wakeword`) is trained from. Nothing here is
/// transcribed or sent anywhere: capture is local-only, and export is the one way this data ever
/// leaves the device.
public struct WakeWordSample: Codable, Sendable, Equatable, Identifiable {
    /// Whether this take says the wake word, or is a negative — some other speech, or ambient
    /// noise, that the trainer wants to learn is *not* "computer".
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        case positive, negative
    }

    /// `WakeWordSampleNaming.stem(from: fileName)` — the filename's own stem doubles as the id
    /// rather than a second generated value, so there is exactly one place a take's identity
    /// comes from.
    public let id: String
    public let kind: Kind
    /// Freddy's own note on what this run was — "loud windy", "airpods", "tired evening" — so a
    /// batch recorded in one condition can be told apart from another once everything is exported
    /// into one flat manifest.
    public let label: String
    public let fileName: String
    public let recordedAtMs: Double
    public let durationMs: Double
    /// The hardware's own input rate at record time — never resampled, matching
    /// `MicrophoneCapture.onRawChunk`'s own reasoning: a training sample should carry whatever the
    /// microphone actually produced, not a rate chosen for a transcriber's transport.
    public let sampleRate: Int
    /// `AVAudioSession.currentRoute`'s input port name at record time — AirPods, a wired headset,
    /// or the phone's own microphone. The single most useful field for explaining why a take
    /// sounds the way it does.
    public let microphoneRoute: String

    public init(
        id: String, kind: Kind, label: String, fileName: String, recordedAtMs: Double, durationMs: Double,
        sampleRate: Int, microphoneRoute: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.fileName = fileName
        self.recordedAtMs = recordedAtMs
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.microphoneRoute = microphoneRoute
    }
}

/// The manifest exported alongside every take's WAV — a flat, pretty-printed JSON array rather
/// than a wrapper object, since the array already is the whole of what an offline trainer needs
/// and a wrapper would only be a key nothing else uses. `sortedKeys` so a diff between two exports
/// is a diff of content, not of field order — the same discipline `RecordingReport` already
/// applies to a single recording's own report.
public enum WakeWordSampleManifest {
    public static func encode(_ samples: [WakeWordSample]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(samples)
    }
}
