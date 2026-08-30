import Foundation

/// A rendezvous a streaming-client connection test uses to await a specific callback firing,
/// rather than polling or sleeping a fixed duration — shared by `PaiSseClientConnectionTests` and
/// `PaiTerminalStreamClientConnectionTests`. Mirrors the `Gate` in `DraftStoreTests`.
actor PaiStreamConnectionSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func fire() {
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
