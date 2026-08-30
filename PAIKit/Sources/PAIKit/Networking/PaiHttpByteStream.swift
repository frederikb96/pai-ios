import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Bridges a streaming HTTP response into an `AsyncThrowingStream` of raw byte chunks, via
/// `URLSessionDataDelegate` rather than `URLSession.bytes(for:)`. Two reasons: `bytes(for:)`
/// returns lines through `AsyncLineSequence`, which silently drops blank lines (see
/// `LineSplitter`'s doc comment) — and swift-corelibs-foundation does not implement `bytes(for:)`
/// at all, which is why `PaiSseClient` and `PaiTerminalStreamClient` used to be excluded from the
/// Linux build (see `Package.swift`). A delegate receives `Data` in whatever boundaries the
/// network happens to hand it over, and — unlike `bytes(for:)` — goes through the same
/// `URLProtocol` machinery `PaiStubURLProtocol` already stubs for the REST client, so the
/// streaming clients are reachable by the same fixture-based tests for the first time.
///
/// Line framing is `LineSplitter`'s job, kept separate so it stays a pure, dependency-free type.
final class PaiHttpByteStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum StreamError: Error, Equatable {
        case unexpectedStatus(Int)
    }

    /// `.connected` is yielded once, the moment the response's status is validated — always
    /// before any `.chunk`, since `URLSession` never calls `didReceive data:` before `didReceive
    /// response:`. Delivering it through the same stream rather than a separate callback keeps
    /// the two strictly ordered without a second hop onto the consumer's actor, which a
    /// callback fired from an arbitrary delegate-queue thread would otherwise need.
    enum Event: Sendable, Equatable {
        case connected
        case chunk(Data)
    }

    // Delegate callbacks run on whatever thread `URLSession` schedules them on, outside Swift
    // concurrency's control — `PaiStubURLProtocol` guards its static state the same way.
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?
    private var task: URLSessionDataTask?
    /// A session created with a delegate is retained by the URL Loading System until explicitly
    /// invalidated — never calling `invalidateAndCancel()`/`finishTasksAndInvalidate()` leaked
    /// one session (and this delegate, and everything it holds) per connection attempt, which for
    /// a client that reconnects on a schedule adds up fast. Read and cleared together under
    /// `lock` in `cancel()`/`finish(throwing:)`, so whichever of the two runs first is the only
    /// one that actually invalidates — a second invalidate call on an already-nilled `session` is
    /// simply a no-op rather than a second call into a `URLSession` API whose repeat-call
    /// behaviour is not the thing worth relying on here.
    private var session: URLSession?

    override init() {}

    /// Starts the request and returns its events. `configuration` defaults to `.default`, but a
    /// caller injects one with `protocolClasses` set to a stub for tests — `PaiStubURLProtocol`'s
    /// own `startLoading()` translates into these same delegate callbacks.
    func start(request: URLRequest, configuration: URLSessionConfiguration = .default) -> AsyncThrowingStream<
        Event, Error
    > {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            let task = session.dataTask(with: request)
            self.task = task
            task.resume()
        }
    }

    /// Cancels the in-flight request — `didCompleteWithError` still fires afterward, ending the
    /// stream the caller is iterating rather than leaving it awaiting an event that never comes.
    /// `invalidateAndCancel()` rather than a plain `task.cancel()`: it cancels the outstanding
    /// task *and* invalidates the session in one call, which a deliberate, caller-initiated
    /// cancel wants immediately rather than waiting for the task to wind down on its own.
    func cancel() {
        lock.lock()
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            finish(throwing: StreamError.unexpectedStatus(status))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(.connected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(.chunk(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(throwing: error)
    }

    /// `finishTasksAndInvalidate()` rather than `invalidateAndCancel()`: by the time this runs,
    /// the task is either already complete (`didCompleteWithError`) or about to be told to cancel
    /// by the caller right after this returns (the early-rejection path in `didReceive
    /// response:`) — either way there is nothing left to force-stop, only a session to release
    /// once it is done winding down.
    private func finish(throwing error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
