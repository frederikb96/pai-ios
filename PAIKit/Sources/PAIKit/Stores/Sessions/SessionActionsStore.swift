import Foundation
import Observation

/// The narrow slice of `PaiApiClient` the session actions menu needs.
public protocol SessionActionsApiClient: Sendable {
    func renameSession(sessionId: String, title: String) async throws -> Session
    func setTitleLocked(sessionId: String, locked: Bool) async throws -> Session
    func closeSession(sessionId: String) async throws -> CloseResponse
    func setIdleTimeout(sessionId: String, minutes: Int?) async throws -> Session
    func exportSession(sessionId: String, since: String?) async throws -> PaiExportResult
}

extension PaiApiClient: SessionActionsApiClient {}

/// The export sheet's presets — `.all` omits `since` entirely and exports the whole session.
/// Swift port of `export.ts`'s `ExportPreset`/`sinceIsoForPreset`.
public enum ExportPreset: CaseIterable, Sendable, Equatable {
    case all, lastHour, last24Hours, last7Days

    public var label: String {
        switch self {
        case .all: return "Whole session"
        case .lastHour: return "Last hour"
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        }
    }

    private var interval: TimeInterval? {
        switch self {
        case .all: return nil
        case .lastHour: return 3600
        case .last24Hours: return 86400
        case .last7Days: return 7 * 86400
        }
    }

    /// The `since` value to send — `nil` for `.all`, meaning omit the query param.
    public func sinceIso(now: Date = Date()) -> String? {
        guard let interval else { return nil }
        return ISO8601DateFormatter().string(from: now.addingTimeInterval(-interval))
    }
}

/// Every action the session actions menu offers, built fresh per presentation (the same lifetime
/// shape `CreateSessionStore` uses) and scoped to one session. Swift port of the mutating half of
/// `web/src/components/SessionActionsMenu.tsx` — delete's immediate-removal shape lives on
/// `SessionListStore` itself (`deleteSession(id:)`), since it is the list's row that disappears,
/// not a fact about one menu instance.
///
/// Every mutation here writes its result back into `sessionList` via `replaceSession(_:)` so the
/// row (and the open header, which reads through the same store) reflects it immediately rather
/// than waiting for the next poll.
@MainActor
@Observable
public final class SessionActionsStore {
    public let sessionId: String
    private let sessionList: SessionListStore
    private let api: SessionActionsApiClient

    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    public init(sessionId: String, sessionList: SessionListStore, api: SessionActionsApiClient) {
        self.sessionId = sessionId
        self.sessionList = sessionList
        self.api = api
    }

    public var session: Session? { sessionList.session(withId: sessionId) }

    @discardableResult
    public func rename(title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await run { try await self.api.renameSession(sessionId: self.sessionId, title: trimmed) }
    }

    /// The rename sheet's own checkbox is phrased "follow the phase name from the VM" — checked
    /// means unlocked (`!locked`), matching the web (`SessionActionsMenu.tsx`'s `saveRename`
    /// subview) exactly, so a caller reading this store's `session?.titleLocked` for that
    /// checkbox's initial state does not have to re-derive the inversion itself.
    @discardableResult
    public func setTitleLocked(_ locked: Bool) async -> Bool {
        await run { try await self.api.setTitleLocked(sessionId: self.sessionId, locked: locked) }
    }

    @discardableResult
    public func close() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.closeSession(sessionId: sessionId)
            if result.status == .closeError {
                errorMessage = result.detail ?? "Could not close the session"
                return false
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not close the session"
            return false
        }
    }

    @discardableResult
    public func setIdleTimeout(minutes: Int?) async -> Bool {
        await run { try await self.api.setIdleTimeout(sessionId: self.sessionId, minutes: minutes) }
    }

    public func exportTranscript(since: String?) async -> PaiExportResult? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.exportSession(sessionId: sessionId, since: since)
            errorMessage = nil
            return result
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Export failed"
            return nil
        }
    }

    /// Removes the row from the list and fires the real DELETE at once — see
    /// `SessionListStore.deleteSession`'s doc comment for why there is no hold and no undo.
    public func deleteNow() {
        sessionList.deleteSession(id: sessionId)
    }

    // MARK: - Private

    private func run(_ request: @escaping () async throws -> Session) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await request()
            sessionList.replaceSession(updated)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "That didn't go through"
            return false
        }
    }
}
