import Foundation
import Observation

/// What `PushChannelsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol PushChannelsApiClient: Sendable {
    func getPushChannels() async throws -> PushChannelsResponse
}

extension PaiApiClient: PushChannelsApiClient {}

/// One switch on the device's notifications settings.
public struct PushChannelRow: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let description: String
}

/// The channels the server offers this account. The app keeps no copy of their ids, labels or
/// descriptions: a channel added server-side shows up as a switch on the next load.
@MainActor
@Observable
public final class PushChannelsStore {
    /// `nil` until a load has succeeded, so a view can tell "not loaded" from "none offered".
    public private(set) var channels: [PushChannelInfo]?

    private let api: any PushChannelsApiClient

    public init(api: any PushChannelsApiClient) {
        self.api = api
    }

    /// A no-op once a load has succeeded; a failure leaves `channels` as it was so the next
    /// call retries.
    public func load() async {
        guard channels == nil else { return }
        if let response = try? await api.getPushChannels() {
            channels = response.channels
        }
    }

    public var offeredIds: [String] { (channels ?? []).map(\.id) }

    /// The switches to draw: the served channels in the server's order, then any channel this
    /// device holds muted that the server no longer lists. Without those, a mute left over from
    /// another build would be unreachable, and the registration would carry it forever.
    public func rows(muted: Set<String>) -> [PushChannelRow] {
        let served = (channels ?? []).map { PushChannelRow(id: $0.id, label: $0.label, description: $0.description) }
        guard channels != nil else { return served }
        let known = Set(served.map(\.id))
        let unknown = muted.subtracting(known).sorted().map {
            PushChannelRow(id: $0, label: $0, description: "A channel this version of the app does not know.")
        }
        return served + unknown
    }
}
