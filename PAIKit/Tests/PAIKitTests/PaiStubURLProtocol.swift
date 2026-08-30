import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A minimal `URLProtocol` stub so `PaiApiClient` tests exercise the real request-building and
/// response-decoding path — query items, body, headers, status handling — without a network
/// call. Static state is lock-protected rather than actor-isolated: `URLProtocol` callbacks run
/// on whatever thread `URLSession` schedules them on, outside Swift concurrency's control.
final class PaiStubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        /// When set, `startLoading()` delivers the body across these `didLoad` calls instead of
        /// one — proving a streaming client reassembles content (and framing) the network
        /// happened to split across chunk boundaries, rather than only ever seeing it whole.
        var bodyChunks: [Data]? = nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub: Stub?
    nonisolated(unsafe) private static var _capturedRequest: URLRequest?
    nonisolated(unsafe) private static var _capturedBody: Data?

    static var stub: Stub? {
        get { lock.lock(); defer { lock.unlock() }; return _stub }
        set { lock.lock(); defer { lock.unlock() }; _stub = newValue }
    }

    static var capturedRequest: URLRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _capturedRequest }
        set { lock.lock(); defer { lock.unlock() }; _capturedRequest = newValue }
    }

    static var capturedBody: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _capturedBody }
        set { lock.lock(); defer { lock.unlock() }; _capturedBody = newValue }
    }

    static func reset() {
        stub = nil
        capturedRequest = nil
        capturedBody = nil
    }

    /// Shared by every stub-backed test, including the delegate-based streaming clients — those
    /// build their own `URLSession` around this configuration rather than reusing `makeSession()`,
    /// since they need to pass their own delegate.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PaiStubURLProtocol.self]
        return configuration
    }

    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody =
            request.httpBody
            ?? request.httpBodyStream.map { stream -> Data in
                stream.open()
                defer { stream.close() }
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while stream.hasBytesAvailable {
                    let read = stream.read(&buffer, maxLength: bufferSize)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                return data
            }

        guard let stub = Self.stub, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunks = stub.bodyChunks {
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
