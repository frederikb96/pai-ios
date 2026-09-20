import PAIKit

/// The one door onto the voice screen, used by every entry point that has one: the launcher's
/// Computer tile, a composer's plus menu, and the app-wide call bar.
///
/// Three things have to happen together and in this order, which is why they live here rather
/// than being written out at each door. The phone has one microphone, so a dictation take
/// already running must stop before Computer's own full-duplex session claims it. The screen is
/// surfaced immediately rather than after the connect, so a tap is never a button that appears
/// to do nothing. And a call already running is joined rather than restarted — every door leads
/// to the same call, whichever face it is currently showing.
@MainActor
enum ComputerCallEntry {
    /// `connectSession` opens the call straight inside that Kai session rather than with
    /// Computer — the launcher's call tiles and a composer's "Call this session".
    ///
    /// A call already running is joined as it is, whatever was asked for: the phone has one
    /// microphone and one call, so a second request cannot open a second one, and silently
    /// hanging the first up to honour the new destination would take a live conversation away
    /// without being asked.
    static func open(_ environment: AppEnvironment, connectSession: String? = nil) {
        guard let connection = environment.connection else { return }
        environment.router.surface(.computerCall)
        Task {
            if connection.voice.state != .idle {
                await connection.voice.stop()
            }
            guard connection.computerCall.session.canStart else { return }
            await connection.computerCall.start(connectSession: connectSession)
        }
    }
}
