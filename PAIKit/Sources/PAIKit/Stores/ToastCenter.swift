import Foundation
import Observation

/// One transient message a toast overlay shows and then removes on its own.
///
/// `action` is what a toast needs beyond plain text — the undo-delete toast is the reason this
/// exists at all, and an undo with no button is not an undo.
public struct ToastMessage: Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let kind: Kind
    public let action: Action?

    public enum Kind: Sendable, Equatable {
        case info, error
    }

    public struct Action: Sendable {
        public let label: String
        public let handler: @Sendable @MainActor () -> Void

        public init(label: String, handler: @escaping @Sendable @MainActor () -> Void) {
            self.label = label
            self.handler = handler
        }
    }

    public init(id: UUID = UUID(), text: String, kind: Kind = .info, action: Action? = nil) {
        self.id = id
        self.text = text
        self.kind = kind
        self.action = action
    }
}

/// App-wide home for a toast/snackbar — there was nowhere for one before this, so every failure
/// in the session actions menu rendered as inline text in whichever view caused it. One shared
/// instance (`AppEnvironment.Connection.toasts`) mounted once at the root, matching the web's
/// `useUiStore`/`ToastContainer`.
@MainActor
@Observable
public final class ToastCenter {
    public private(set) var toasts: [ToastMessage] = []

    /// How long an ordinary toast stays before it removes itself. The web's `addToast` has no
    /// timeout at all — Freddy dismisses it by hand — but a phone has no idle mouse hovering over
    /// a corner to notice one sitting there forever, so this gives it a life of its own instead.
    public static let autoDismissNanos: UInt64 = 4_000_000_000

    public init() {}

    /// Shows a message and lets it dismiss itself after `lifetimeNanos`. A toast carrying an
    /// `action` (the undo-delete case) must pass the same window the action itself stays live
    /// for — ``SessionListStore/deleteUndoNanos`` — so the button can never outlive what it undoes.
    @discardableResult
    public func show(
        _ text: String, kind: ToastMessage.Kind = .info, action: ToastMessage.Action? = nil,
        lifetimeNanos: UInt64 = ToastCenter.autoDismissNanos
    ) -> UUID {
        let toast = ToastMessage(text: text, kind: kind, action: action)
        toasts.append(toast)
        Task { [weak self, id = toast.id] in
            try? await Task.sleep(nanoseconds: lifetimeNanos)
            self?.dismiss(id)
        }
        return toast.id
    }

    public func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}
