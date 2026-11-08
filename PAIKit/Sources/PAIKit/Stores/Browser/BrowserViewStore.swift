import Foundation
import Observation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One agent browser session, live: its connection, its newest state and frame, the input going
/// back, and the Done / Couldn't buttons. Swift port of the state half of `LiveView.tsx`.
///
/// The picture itself is not state: each frame goes to ``onFrame``, which the screen's drawing
/// surface sets, so a frame arriving five times a second does not re-evaluate the SwiftUI body.
@MainActor
@Observable
public final class BrowserViewStore {

    public enum Status: Equatable, Sendable {
        case connecting
        case live
        case reconnecting
        case ended(reason: String)
    }

    public enum Handback: Equatable, Sendable {
        case idle
        case sending
        /// What the backend said, or why the call failed.
        case finished(message: String)
    }

    public let name: String
    public private(set) var session: BrowserSession?
    public private(set) var status = Status.connecting
    public private(set) var hasFrame = false
    public private(set) var handback = Handback.idle

    /// Touches become input and zoom here; the drawing surface feeds it.
    @ObservationIgnored public let gestures = BrowserGestureInterpreter()
    /// Called with every decoded frame, newest last.
    @ObservationIgnored public var onFrame: ((BrowserFrame) -> Void)?

    private let api: BrowserApiClient
    private let requestFactory: PaiRequestFactory
    private let urlSessionConfiguration: URLSessionConfiguration
    @ObservationIgnored private var queue: BrowserInputQueue?
    @ObservationIgnored private var client: PaiBrowserStreamClient?
    @ObservationIgnored private var latestFrame: BrowserFrame?

    public init(
        name: String, api: BrowserApiClient, requestFactory: PaiRequestFactory,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.name = name
        self.api = api
        self.requestFactory = requestFactory
        self.urlSessionConfiguration = urlSessionConfiguration
        let api = self.api
        let name = self.name
        queue = BrowserInputQueue { input in try await api.sendBrowserInput(name: name, input: input) }
        gestures.send = { [weak self] input in self?.send(input) }
    }

    // MARK: Connection

    /// Opens the stream. Idempotent: a screen that reappears over a stream that is still open
    /// changes nothing.
    public func start() {
        guard client == nil else { return }
        if case .ended = status { return }
        let newClient = PaiBrowserStreamClient(
            sessionName: name, requestFactory: requestFactory,
            callbacks: PaiBrowserStreamClient.Callbacks(
                onEvent: { [weak self] in self?.apply($0) },
                onConnected: { [weak self] in self?.connected() },
                onDisconnected: { [weak self] in self?.disconnected() }),
            urlSessionConfiguration: urlSessionConfiguration)
        client = newClient
        newClient.connect()
    }

    /// Closes the stream; the backend stops the session's screencast when the last viewer leaves.
    public func stop() {
        client?.disconnect()
        client = nil
    }

    func connected() {
        if case .ended = status { return }
        status = .live
    }

    func disconnected() {
        guard client != nil else { return }
        if case .ended = status { return }
        status = .reconnecting
    }

    func apply(_ event: BrowserStreamEvent) {
        switch event {
        case .frame(let frame):
            latestFrame = frame
            gestures.setFrameSize(BrowserSize(w: frame.w, h: frame.h))
            hasFrame = true
            onFrame?(frame)
        case .state(let state):
            session = state
        case .end(let reason):
            status = .ended(reason: reason)
            client = nil
        }
    }

    /// The newest frame, for a drawing surface that appears after it arrived.
    public var newestFrame: BrowserFrame? { latestFrame }

    // MARK: Input

    public func send(_ input: BrowserInput) {
        queue?.push(input)
    }

    /// The text field's contents into whatever the page has focused, optionally followed by Enter.
    public func sendTyped(_ text: String, thenEnter: Bool) {
        if !text.isEmpty { send(.text(text)) }
        if thenEnter { send(.key("Enter")) }
    }

    // MARK: Handover

    public func finish(_ result: BrowserHandbackResult) async {
        guard handback != .sending else { return }
        handback = .sending
        do {
            let answer = try await api.handBackBrowserSession(name: name, result: result, note: nil)
            handback = .finished(
                message: answer.messaged
                    ? "Sent to the conversation."
                    : "Handed back, but nobody was messaged: \(answer.reason ?? "unknown").")
        } catch {
            handback = .finished(message: (error as? PaiError)?.userMessage ?? "Could not hand back.")
        }
    }
}
