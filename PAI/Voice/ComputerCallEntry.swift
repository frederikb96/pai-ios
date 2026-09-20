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
    static func open(_ environment: AppEnvironment) {
        guard let connection = environment.connection else { return }
        environment.router.surface(.computerCall)
        Task {
            if connection.voice.state != .idle {
                await connection.voice.stop()
            }
            guard connection.computerCall.session.canStart else { return }
            await connection.computerCall.start()
        }
    }
}
