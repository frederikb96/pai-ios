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

    override init() {}

    /// Starts the request and returns its events. `configuration` defaults to `.default`, but a
    /// caller injects one with `protocolClasses` set to a stub for tests — `PaiStubURLProtocol`'s
    /// own `startLoading()` translates into these same delegate callbacks.
    func start(request: URLRequest, configuration: URLSessionConfiguration = .default) -> AsyncThrowingStream<
        Event, Error
    > {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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
    func cancel() {
        task?.cancel()
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

    private func finish(throwing error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }
}
