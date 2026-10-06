import Foundation
import Observation

public protocol UsageApiClient: Sendable {
    func getUsage() async throws -> Usage
}

extension PaiApiClient: UsageApiClient {}

/// One plan window as the Usage screen shows it. Everything a view needs is a value here, so the
/// decisions are proven on Linux rather than read out of a view.
public struct UsageRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// Percent (0-100) of the window consumed — a PERCENT, the same unit as `linePercent`.
    public let utilization: Double
    /// Where the even-pace line sits now, in percent of the window; `nil` when no line is known.
    public let linePercent: Double?
    public let tone: UsagePaceTone
    /// "15 points over a steady pace of 25%"; `nil` when no line is known.
    public let paceDescription: String?
    public let resetsAt: String?
}

public enum UsageDisplay {
    /// Plan-wide windows first, then each per-model weekly cap (e.g. Fable). A window the agent
    /// did not report has no row.
    public static func rows(_ usage: Usage) -> [UsageRow] {
        var rows: [UsageRow] = []
        if let window = usage.fiveHour { rows.append(row(id: "five_hour", label: "5-hour", window)) }
        if let window = usage.sevenDay { rows.append(row(id: "seven_day", label: "7-day", window)) }
        for scoped in usage.sevenDayModels ?? [] {
            rows.append(row(id: "model:\(scoped.model)", label: "7-day \(scoped.model)", scoped))
        }
        return rows
    }

    private static func row<W: PacedWindow>(id: String, label: String, _ window: W) -> UsageRow {
        return UsageRow(
            id: id, label: label, utilization: window.utilization,
            linePercent: window.pace?.linePercent, tone: window.paceTone,
            paceDescription: window.paceDescription, resetsAt: window.resetsAt)
    }
}

/// The Usage app's state. Swift port of `UsageApp.tsx`.
@MainActor
@Observable
public final class UsageStore {
    public private(set) var usage: Usage?
    public private(set) var isLoading = true
    public private(set) var errorMessage: String?

    public var rows: [UsageRow] { usage.map(UsageDisplay.rows) ?? [] }

    private let api: UsageApiClient

    public init(api: UsageApiClient) {
        self.api = api
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            usage = try await api.getUsage()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load plan usage"
        }
    }
}
