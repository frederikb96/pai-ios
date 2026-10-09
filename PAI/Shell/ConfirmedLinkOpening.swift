import PAIKit
import SwiftUI

/// Asks before leaving the app for an `http`/`https` link — a touchscreen tap can land on a link
/// by accident where a mouse click rarely does, so an https link gets the same confirmation
/// style a note-to-note wikilink already has in ``NoteBodyView``, rather than opening immediately.
///
/// `onNoteLink` lets a caller keep its own handling for an in-app note deep link — confirmed here
/// too, with its own wording, before the closure runs. A link to a heading of the page it is read
/// on (`NoteLinkTarget.id` empty) is a scroll, not a navigation, so it runs the closure at once.
/// Passed `nil`, a note link falls through to `.systemAction` exactly like any other URL that is
/// not `http`/`https`.
struct ConfirmedLinkOpening: ViewModifier {
    var onNoteLink: ((NoteLinkTarget) -> Void)?

    @State private var pendingNoteLink: NoteLinkTarget?
    @State private var pendingExternalURL: URL?

    func body(content: Content) -> some View {
        content
            .environment(
                \.openURL,
                OpenURLAction { url in
                    if let onNoteLink, let target = NoteLinkTarget.parse(url) {
                        if target.id.isEmpty {
                            onNoteLink(target)
                        } else {
                            pendingNoteLink = target
                        }
                        return .handled
                    }
                    guard url.scheme == "http" || url.scheme == "https" else { return .systemAction }
                    pendingExternalURL = url
                    return .handled
                }
            )
            .confirmationDialog(
                "Open this note?",
                isPresented: Binding(get: { pendingNoteLink != nil }, set: { if !$0 { pendingNoteLink = nil } }),
                titleVisibility: .visible
            ) {
                Button("Open") {
                    if let target = pendingNoteLink { onNoteLink?(target) }
                    pendingNoteLink = nil
                }
                Button("Cancel", role: .cancel) { pendingNoteLink = nil }
            }
            .confirmationDialog(
                "Open this link?",
                isPresented: Binding(
                    get: { pendingExternalURL != nil }, set: { if !$0 { pendingExternalURL = nil } }),
                titleVisibility: .visible
            ) {
                Button("Open") {
                    if let url = pendingExternalURL { UIApplication.shared.open(url) }
                    pendingExternalURL = nil
                }
                Button("Cancel", role: .cancel) { pendingExternalURL = nil }
            }
    }
}

extension View {
    /// See ``ConfirmedLinkOpening``.
    func confirmingExternalLinks(onNoteLink: ((NoteLinkTarget) -> Void)? = nil) -> some View {
        modifier(ConfirmedLinkOpening(onNoteLink: onNoteLink))
    }
}
