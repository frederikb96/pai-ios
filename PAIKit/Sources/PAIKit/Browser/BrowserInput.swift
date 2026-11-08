import Foundation

/// One input event as `POST /api/browser/sessions/{name}/input` accepts it; coordinates are page
/// CSS pixels of the newest frame. Swift port of `BrowserInput` in `browserModel.ts`.
public enum BrowserInput: Equatable, Sendable, Encodable {
    public enum MouseAction: String, Sendable { case move, down, up, click }
    public enum MouseButton: String, Sendable { case left, right, middle }
    public enum NavAction: String, Sendable { case goto, back, forward, reload }

    case mouse(action: MouseAction, x: Double, y: Double, button: MouseButton)
    case wheel(x: Double, y: Double, dx: Double, dy: Double)
    /// A Playwright key name such as `Enter` or `Control+a`.
    case key(String)
    case text(String)
    case nav(NavAction, url: String? = nil)

    private enum CodingKeys: String, CodingKey {
        case t, action, x, y, dx, dy, button, key, text, url
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .mouse(let action, let x, let y, let button):
            try container.encode("mouse", forKey: .t)
            try container.encode(action.rawValue, forKey: .action)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(button.rawValue, forKey: .button)
        case .wheel(let x, let y, let dx, let dy):
            try container.encode("wheel", forKey: .t)
            try container.encode(x, forKey: .x)
            try container.encode(y, forKey: .y)
            try container.encode(dx, forKey: .dx)
            try container.encode(dy, forKey: .dy)
        case .key(let key):
            try container.encode("key", forKey: .t)
            try container.encode(key, forKey: .key)
        case .text(let text):
            try container.encode("text", forKey: .t)
            try container.encode(text, forKey: .text)
        case .nav(let action, let url):
            try container.encode("nav", forKey: .t)
            try container.encode(action.rawValue, forKey: .action)
            try container.encodeIfPresent(url, forKey: .url)
        }
    }
}

/// Sends input events strictly one at a time, in order (a mouse-down must not overtake the move
/// before it), merging what is safe to merge while a request is in flight: consecutive wheel
/// deltas add up. Without that a finger drag would queue hundreds of POSTs behind a slow
/// connection. Swift port of `inputQueue.ts`.
///
/// A failed send is dropped, not retried: replaying a stale click later would be worse than
/// losing it.
@MainActor
public final class BrowserInputQueue {
    private var pending: [BrowserInput] = []
    private var isFlushing = false
    private let send: @Sendable (BrowserInput) async throws -> Void

    public init(send: @escaping @Sendable (BrowserInput) async throws -> Void) {
        self.send = send
    }

    public func push(_ input: BrowserInput) {
        if case .wheel(_, _, let lastDx, let lastDy)? = pending.last,
            case .wheel(let x, let y, let dx, let dy) = input
        {
            pending[pending.count - 1] = .wheel(x: x, y: y, dx: lastDx + dx, dy: lastDy + dy)
        } else if case .mouse(.move, _, _, _)? = pending.last, case .mouse(.move, _, _, _) = input {
            pending[pending.count - 1] = input
        } else {
            pending.append(input)
        }
        guard !isFlushing else { return }
        isFlushing = true
        Task { await flush() }
    }

    private func flush() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            try? await send(next)
        }
        isFlushing = false
    }
}
