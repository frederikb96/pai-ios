import Foundation
import Observation

public protocol BrowserApiClient: Sendable {
    func listBrowserSessions() async throws -> [BrowserSession]
    func sendBrowserInput(name: String, input: BrowserInput) async throws
    func handBackBrowserSession(name: String, result: BrowserHandbackResult, note: String?) async throws
        -> BrowserHandbackAnswer
}

extension PaiApiClient: BrowserApiClient {}

/// The Browser app's list: the agent's live browser sessions, those waiting on the owner first.
/// Swift port of `SessionList` in `BrowserApp.tsx`.
///
/// Owner only: the routes answer a guest 403, so a guest never sends a request.
@MainActor
@Observable
public final class BrowserSessionsStore {
    /// How often the list is re-read while it is on screen.
    public static let refreshInterval: TimeInterval = 4

    /// `nil` until the first read lands.
    public private(set) var sessions: [BrowserSession]?
    public private(set) var errorMessage: String?

    private let api: BrowserApiClient
    private let capabilities: @MainActor () -> Capabilities

    public init(api: BrowserApiClient, capabilities: @escaping @MainActor () -> Capabilities) {
        self.api = api
        self.capabilities = capabilities
    }

    public var ownerMayBrowse: Bool { capabilities().canOpenBrowser }

    /// A failed read keeps the list it already has and shows the error beside it.
    public func load() async {
        guard capabilities().canOpenBrowser else { return }
        do {
            sessions = Self.ordered(try await api.listBrowserSessions())
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the browser sessions"
        }
    }

    /// Reads the list again every ``refreshInterval`` until the calling task is cancelled.
    public func keepFresh() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(nanoseconds: UInt64(Self.refreshInterval * 1_000_000_000))
        }
    }

    /// Sessions waiting on the owner first, then the most recently used. The timestamps are
    /// compared as the strings the backend sends, as the web does.
    nonisolated public static func ordered(_ sessions: [BrowserSession]) -> [BrowserSession] {
        sessions.sorted { a, b in
            if (a.handoff != nil) != (b.handoff != nil) { return a.handoff != nil }
            return a.lastUsedAt > b.lastUsedAt
        }
    }
}
