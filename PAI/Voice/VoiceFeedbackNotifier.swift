import PAIKit
import UserNotifications

/// The connection-health half of the design: turns every `FeedbackEvent` a take produces into an
/// earcon and, through `FeedbackPolicy`, into a local notification — one per take, updated in
/// place rather than stacking on a bad ride. This is what tells Freddy the moment anything flaky
/// happens, even when recovery is fully automatic and nothing else on screen would show it.
///
/// Covers every reason a take can end or hit trouble — the tap, silence, a give-up, an
/// interruption that could not resume — by reusing one notification request per take rather than
/// posting a fresh one per event, so a flapping ride produces one banner, not thirty.
///
/// Owns no authorization request of its own — `PushRegistrar` is the one claimant of the system
/// prompt; this silently no-ops when notifications were never authorized.
@MainActor
final class VoiceFeedbackNotifier {
    /// What the thing being reported on is, for the handful of bodies whose claim differs.
    /// A dictation take keeps capturing through a drop and backfills the gap afterwards, so
    /// "recording continues" is true there; a call has no such buffer — `ComputerCallSession`
    /// drops every chunk it cannot send — so the same words would promise something no part of
    /// the app does.
    enum Subject {
        case dictation
        case call
    }

    private var policy = FeedbackPolicy()
    private let earcons: EarconPlayer
    /// Every request this take posts is scoped under this id, so a fresh take never collides
    /// with — or accidentally updates — a notification left over from the previous one.
    private var takeId: String = "voice"
    private var subject: Subject = .dictation

    init(earcons: EarconPlayer) {
        self.earcons = earcons
    }

    /// Call once per take or call, before its first event — resets the episode and per-cause
    /// dedup state a stale `FeedbackPolicy` would otherwise carry over from whatever came before.
    func beginTake(id: String, subject: Subject = .dictation) {
        takeId = id
        policy = FeedbackPolicy()
        self.subject = subject
    }

    /// The shape `VoiceRecordingDependencies.feedback: (FeedbackEvent) -> Void` wants — a plain,
    /// synchronous, non-`async` closure. Posting a notification is async, so it is dispatched
    /// into its own `Task` rather than making every call site `await` a UI nicety; the cue plays
    /// synchronously first, before that hop, since the cue is what matters most under load.
    func handle(_ event: FeedbackEvent) {
        let action = policy.decide(event, now: Date())
        AppVoiceDiagnosticsLog.shared.log(Self.logLevel(for: event), .feedback, Self.logMessage(for: event))
        if let cue = action.cue {
            earcons.play(cue)
        }
        guard let notify = action.notify else { return }
        Task { await post(notify) }
    }

    /// What actually reached the log — deliberately independent of `title(for:)`/`body(for:)`
    /// below, which only run when `FeedbackPolicy` decided a notification was worth posting.
    /// Every event is worth a log line even when `FeedbackPolicy` swallows it as a repeat.
    private static func logLevel(for event: FeedbackEvent) -> VoiceLogLevel {
        switch event {
        case .connectionDropped, .serverNotice, .mintFailed, .fatalProtocolError, .captureGaveUp, .backfillFailed,
            .ttsDropped, .ttsRejected, .replyNotSpoken, .commandModelMissing, .recordingStartFailed, .sendFailed:
            .warning
        case .reconnected, .gapOpened, .backfillCompleted, .captureRestarted, .interruptionPaused,
            .interruptionResumed, .ttsReconnected, .commandRecognized:
            .info
        case .callEndedUnexpectedly:
            .warning
        }
    }

    private static func logMessage(for event: FeedbackEvent) -> String {
        switch event {
        case .connectionDropped(let reason): "connection dropped\(reason.map { " (\($0))" } ?? "")"
        case .serverNotice(let reason): "server notice: \(reason)"
        case .mintFailed: "token mint failed"
        case .reconnected: "reconnected"
        case .gapOpened: "transcription gap opened"
        case .backfillCompleted: "backfill completed — take fully transcribed"
        case .backfillFailed: "backfill failed"
        case .fatalProtocolError(let reason): "fatal protocol error: \(reason)"
        case .captureRestarted: "microphone capture restarted"
        case .captureGaveUp: "microphone capture gave up"
        case .interruptionPaused: "audio session interruption began"
        case .interruptionResumed: "audio session interruption ended"
        case .ttsDropped: "spoken-reply connection dropped"
        case .ttsReconnected: "spoken-reply connection reconnected"
        case .ttsRejected(let reason, let message): "spoken-reply request rejected (\(reason)): \(message)"
        case .replyNotSpoken: "a reply was not spoken"
        case .recordingStartFailed(let reason): "call recording could not connect: \(reason)"
        case .sendFailed: "call turn was not sent"
        case .commandRecognized(let kind): "command recognized: \(kind.rawValue)"
        case .commandModelMissing: "no offline model bundled for the \"computer\" wake word"
        case .callEndedUnexpectedly(let hadUnsentText): "call ended unexpectedly (unsent text: \(hadUnsentText))"
        }
    }

    private func post(_ notify: FeedbackAction.Notify) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title(for: notify.event)
        content.body = body(for: notify)
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        content.threadIdentifier = takeId
        // A repeated identifier replaces the existing request's content rather than adding a
        // second one — the entire mechanism behind "updated in place, not one per event".
        let request = UNNotificationRequest(identifier: "\(takeId)-\(notify.key)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func title(for event: FeedbackEvent) -> String {
        switch event {
        case .captureGaveUp: return "Voice recording stopped"
        case .callEndedUnexpectedly: return "Call ended"
        default: return "Voice"
        }
    }

    /// What is still happening while the connection is down — the half of a drop's wording that
    /// is a promise rather than a report.
    private var continues: String {
        switch subject {
        case .dictation: "recording continues"
        case .call: "reconnecting"
        }
    }

    private func body(for notify: FeedbackAction.Notify) -> String {
        switch notify.event {
        case .connectionDropped, .captureRestarted:
            return notify.episodeDropCount > 1
                ? "Connection lost \(notify.episodeDropCount) times so far — \(continues)."
                : "Connection lost — \(continues)."
        case .serverNotice(let reason):
            return "Connection lost (\(reason)) — \(continues)."
        case .mintFailed:
            return "Server unreachable — \(continues)."
        case .reconnected:
            return notify.episodeDropCount > 0
                ? "Reconnected after \(notify.episodeDropCount) drop\(notify.episodeDropCount == 1 ? "" : "s")."
                : "Reconnected."
        case .gapOpened:
            return "Still catching up on audio not yet transcribed."
        case .backfillCompleted:
            return "All audio transcribed."
        case .backfillFailed:
            return "Some audio could not be transcribed — check Settings › Recordings."
        case .fatalProtocolError(let reason):
            return "Transcription stopped (\(reason)) — recording continues."
        case .captureGaveUp:
            return "The microphone could not be restarted."
        case .ttsDropped:
            return "The spoken-reply connection was lost."
        case .ttsReconnected:
            return "The spoken-reply connection is back."
        case .ttsRejected(let reason, _):
            switch reason {
            case "voice_id_does_not_exist":
                return "Voice not found — check the voice ID in Settings."
            case "authentication_required":
                return "ElevenLabs rejected the request — check the API key in Settings."
            default:
                return "The voice service rejected the request (\(reason))."
            }
        case .replyNotSpoken:
            return "A reply was not spoken — it is in the transcript."
        case .recordingStartFailed(let reason):
            return "Recording is not live (\(reason)) — the audio is kept and transcribed later."
        case .sendFailed:
            // Deliberately hedged: a network failure here can be the request never reaching the
            // server, or the server's own reply to an accepted send never reaching us — this app
            // has no idempotency key to tell the two apart, and claiming "not sent" outright would
            // be wrong exactly when it matters most, encouraging a duplicate send.
            return
                "Your message may not have gone through — the text is back in the draft. Check before sending it again."
        case .commandModelMissing:
            return "The \"computer\" wake word has no offline model bundled yet — a call won't start listening for it."
        case .callEndedUnexpectedly(let hadUnsentText):
            return hadUnsentText
                ? "The call ended — your unsent text is in the draft." : "The call ended."
        case .interruptionPaused, .interruptionResumed, .commandRecognized:
            // `FeedbackPolicy` never emits a `notify` for these — a cue only, no notification.
            return ""
        }
    }
}
