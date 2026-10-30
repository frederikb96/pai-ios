import PAIKit
import SwiftUI
import UIKit

/// A caret move the editor is asking for, as opposed to one the reader made.
///
/// Carries a token because a request has to be applied exactly once. Applied whenever it is
/// present, it would be reapplied on every unrelated redraw — a save finishing, a badge changing —
/// and yank the caret back to where it last was set, minutes after the reader moved it somewhere
/// else.
struct CaretRequest: Equatable {
    let token: Int
    /// A UTF-16 offset into the note's whole source.
    let offset: Int
    /// Whether this is an arrival rather than a keystroke's own caret move — an outline heading, a
    /// search hit — and so should settle a third of the way down the page instead of scrolling by
    /// the minimum. See ``MarkdownSourceTextView/Coordinator/bringCaretIntoView(_:settlingAtTopThird:)``.
    var settlesAtTopThird: Bool = false
}

/// The note's whole markdown source, in one wrapping, editable, self-scrolling text view.
///
/// Fenced code and tables lay out inside this same view rather than in their own non-wrapping,
/// sideways-scrolling region — nobody needs a raw `| a | b |` source line to scroll sideways to be
/// readable, and the *rendered* table's own unwrapped grid is preview's job, a completely separate
/// renderer. One text view for the whole note is also what makes an ordinary paragraph break,
/// Backspace and Undo simply UIKit's own behaviour, with no seam anywhere for this editor to get
/// wrong.
///
/// What keeps that one view usable on a note of any size is that no keystroke may cost in
/// proportion to the note. The text view owns the text while it is open; everything else works
/// from the edit: a ``MarkdownDocumentIndex`` answers line questions, a repaint touches only the
/// edited lines, and the store hears about the text on a timer rather than per key. TextKit 1
/// lays the whole note out once at open, so every height on screen is a measured one and a jump
/// lands exactly; a large note does that behind a loading state, in slices.
struct MarkdownSourceTextView: UIViewRepresentable {

    /// The padding TextKit lays the note out inside.
    static let horizontalInset: CGFloat = 14
    static let topInset: CGFloat = 16
    /// Room to scroll the last line up from the bottom edge, and to tap below it.
    static let bottomInset: CGFloat = 150

    /// Above this many UTF-16 units a note is painted and laid out behind a loading state. Below
    /// it the work is too small to see and the note is simply there in the first frame.
    static let backgroundLoadLength = 32_000

    /// The body as the store holds it. A closure so that a view update never holds the note as a
    /// value: SwiftUI compares a view's properties on every update, a whole note included.
    let text: () -> String
    /// Changes when the body was replaced by something other than typing. The only thing that
    /// makes this view read `text` again after it opened: see ``NotesStore/externalBodyRevision``.
    let revision: Int
    let isFocused: Bool
    /// Where the editor wants the caret, when something outside the text view asked to jump there.
    /// Nil means leave the caret alone, which is every ordinary keystroke.
    let caret: CaretRequest?
    /// Text to place into the note through the text view's own editing path.
    let insertion: NoteInsertion?
    /// What the in-note search is looking for. Every occurrence stays painted while it is set,
    /// which is what makes "find in note" usable without leaving the editor.
    let highlight: String?
    /// Which actions the keyboard bar offers, and in which order — Settings'
    /// `noteToolbarLayout`, read fresh on every update so a change made while this
    /// editor is open reaches the already-built bar rather than only a freshly opened one.
    let toolbarLayout: [NoteToolbarActionId]
    /// The gutter and the wrap indent, one visual feature behind one setting.
    let showsLineNumbers: Bool
    let handle: NoteEditorHandle

    /// The text as it now stands, at a pause in typing: see ``Coordinator/publishPause``.
    let onChange: (String) -> Void
    let onFocus: () -> Void
    /// The keyboard bar's paperclip, carrying the caret's UTF-16 offset — where whatever is picked
    /// has to end up. Captured at the tap because presenting a picker takes the keyboard away, and
    /// with it the selection.
    let onAttach: (Int) -> Void
    /// A pasted image, landing wherever the caret was at the moment of the paste — the same
    /// `PastedImage` shape and the same `PasteAwareTextView` the session composer already pastes
    /// images through, reused rather than reimplemented (see that type's own doc comment for why
    /// a plain `UITextView` needs it at all: `Paste` only appears when the pasteboard holds text).
    let onPasteImages: (Int, [PastedImage]) -> Void
    /// Whether a background load is running, for the screen to show it.
    let onLoadingChange: (Bool) -> Void
    /// The text was replaced from outside, so anything aimed at the old text no longer applies.
    let onReplaced: () -> Void

    func makeUIView(context: Context) -> NoteSourceTextView {
        // TextKit 1, explicitly. Its heights are measured rather than estimated, which is what
        // lets a jump land exactly and a scroll stay still, and its text storage takes attribute
        // edits in place: assigning `attributedText` replaces the whole string, which UIKit records
        // as one wholesale edit and which drops the selection.
        let view = NoteSourceTextView(usingTextLayoutManager: false)
        // The note writes its own embed links for a paste, so nothing comes back for the view to
        // insert.
        view.onPasteImages = { [weak view] images in
            guard let view else { return nil }
            context.coordinator.handlePaste(images, at: view.selectedRange.location)
            return nil
        }
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        view.tintColor = NoteEditorTheme.accent
        view.inputAccessoryView = context.coordinator.keyboardBar
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.spellCheckingType = .default
        // Markdown is punctuation. Smart quotes and dashes would rewrite `--force` and `"a"` as
        // they are typed, which is the same corruption the transcript parser disables smart
        // punctuation to avoid — and here it would be written back to the vault.
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.alwaysBounceVertical = true
        view.textStorage.delegate = context.coordinator
        // Every line is laid out at open all the same (`settleLayout`). What this buys is the
        // edit: a style change leaves a hole to refill, rather than the rest of the note to redo.
        view.layoutManager.allowsNonContiguousLayout = true
        context.coordinator.attach(view)
        context.coordinator.load(text(), into: view)
        return view
    }

    func updateUIView(_ view: NoteSourceTextView, context: Context) {
        let coordinator = context.coordinator
        let layoutChanged = coordinator.parent.toolbarLayout != toolbarLayout
        let gutterChanged = coordinator.parent.showsLineNumbers != showsLineNumbers
        coordinator.parent = self
        if layoutChanged { coordinator.keyboardBar.setLayout(toolbarLayout) }

        if revision != coordinator.appliedRevision {
            coordinator.appliedRevision = revision
            coordinator.adoptExternalBody(in: view)
        } else if gutterChanged {
            // The hang is painted into the text and the gutter narrows its width, so every line
            // reflows anyway.
            coordinator.load(view.nativeText, into: view)
        }
        coordinator.applyRequests(in: view)
    }

    /// Fills what it is offered and asks the view nothing. Left to itself, SwiftUI asks the text
    /// view what size it wants on each update, and a text view answers by measuring the whole
    /// note.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NoteSourceTextView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width, height: proposal.height ?? uiView.bounds.height)
    }

    static func dismantleUIView(_ view: NoteSourceTextView, coordinator: Coordinator) {
        coordinator.publishNow()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownSourceTextView
        /// The last caret request actually applied — see ``CaretRequest``.
        var appliedCaretToken = Int.min
        private var appliedInsertionToken = Int.min
        var appliedRevision: Int
        /// Whether the link form is on screen. It is a UIKit alert presented from here, so SwiftUI
        /// does not know it covers the editor — see ``applyRequests(in:)``.
        var isPresentingLinkForm = false
        /// What the layout manager was last painted for, so a changed query repaints and an
        /// unchanged one does not.
        private var paintedHighlight: String?
        private var highlightToken = 0

        /// Built once and kept, because `inputAccessoryView` is read every time the view becomes
        /// first responder and a fresh bar per focus would flicker as the keyboard comes up.
        lazy var keyboardBar: NoteEditorKeyboardBar = NoteEditorKeyboardBar(
            layout: parent.toolbarLayout, showsFormatting: true
        ) { [weak self] item in
            self?.handle(item)
        }

        /// The text view this coordinator drives. The bar's actions arrive from UIKit with no view
        /// attached to them.
        private weak var textView: NoteSourceTextView?
        private(set) var index = MarkdownDocumentIndex(text: "" as NSString)
        private var loadToken = 0
        /// False from the moment a load starts until the note can be typed into. Every request
        /// waits behind this, so a jump asked for while a large note opens lands when it is ready.
        private(set) var isLoaded = false
        /// Set while the text view takes a whole new text, which the edit path must not read as
        /// an edit of the old one.
        private var isInstalling = false

        /// A repaint waits for a short gap in typing. Only the styling catches up a beat later:
        /// UIKit already drew the raw keystroke.
        private static let repaintDebounce: TimeInterval = 0.12
        /// The most text one main-thread tick repaints, in UTF-16 units. Opening a fence restyles
        /// everything below it, and that must not stop the keyboard.
        private static let repaintSlice = 12_000
        private var repaintWorkItem: DispatchWorkItem?
        /// The range still to repaint, always whole lines of the current text once it is read.
        private var dirty: NSRange?

        /// The store hears the text at a pause in typing, and within ``publishLimit`` of the
        /// first unpublished key however steady the typing is, since the outbox is what survives
        /// the app being killed.
        static let publishPause: TimeInterval = 0.3
        static let publishLimit: TimeInterval = 2
        private var publishWorkItem: DispatchWorkItem?
        private var firstUnpublishedEdit: DispatchTime?

        #if DEBUG
            /// Where the bench reads what a load and a repaint cost.
            var benchLoadMs: Double?
            var benchRepaintsMs: [Double] = []
            var benchPublishesMs: [Double] = []
            var benchTextView: NoteSourceTextView? { textView }
        #endif

        init(parent: MarkdownSourceTextView) {
            self.parent = parent
            appliedRevision = parent.revision
        }

        func attach(_ view: NoteSourceTextView) {
            textView = view
            view.onBoundsChange = { [weak self] view, oldSize in self?.boundsChanged(view, from: oldSize) }
            parent.handle.publishPending = { [weak self] in self?.publishNow() }
            #if DEBUG
                NoteEditorBench.coordinator = self
            #endif
        }

        /// Routed through the coordinator rather than captured directly at `makeUIView` time, the
        /// same reason every other callback here goes through `parent` — a closure captured once,
        /// when the view is first created, would keep calling whatever `onPasteImages` this view
        /// was built with, silently missing any prop change since. `parent` is kept current by
        /// `updateUIView`, so reading it here always calls the caller's latest closure.
        func handlePaste(_ images: [PastedImage], at offset: Int) {
            parent.onPasteImages(offset, images)
        }

        // MARK: Loading

        /// Give the text view a whole new text. The note is built away from the main thread when
        /// it is large, and stays hidden and read-only until its layout is finished, so the reader
        /// is never shown a height that later changes.
        func load(_ text: String, into view: NoteSourceTextView) {
            loadToken += 1
            let token = loadToken
            paintedHighlight = nil
            configureInsets(of: view)
            let showsIndent = parent.showsLineNumbers
            guard text.utf16.count > MarkdownSourceTextView.backgroundLoadLength else {
                install(NoteEditorDocument(text: text, showsHangingIndent: showsIndent), in: view)
                finishLoading(view)
                return
            }
            isLoaded = false
            view.isEditable = false
            view.alpha = 0
            let started = DispatchTime.now()
            DispatchQueue.main.async { [weak self] in self?.parent.onLoadingChange(true) }
            Task { [weak self, weak view] in
                let document = await Task.detached(priority: .userInitiated) {
                    NoteEditorDocument(text: text, showsHangingIndent: showsIndent)
                }.value
                guard let self, let view, token == self.loadToken else { return }
                self.install(document, in: view)
                guard await self.settleLayout(of: view, token: token) else { return }
                #if DEBUG
                    self.benchLoadMs = NoteEditorBench.milliseconds(since: started)
                #endif
                self.finishLoading(view)
                self.parent.onLoadingChange(false)
            }
        }

        private func configureInsets(of view: NoteSourceTextView) {
            let gutter = parent.showsLineNumbers
            view.textContainerInset = UIEdgeInsets(
                top: MarkdownSourceTextView.topInset,
                left: MarkdownSourceTextView.horizontalInset
                    + (gutter ? NoteLineNumberGutter.width + NoteLineNumberGutter.spacing : 0),
                bottom: MarkdownSourceTextView.bottomInset, right: MarkdownSourceTextView.horizontalInset)
            view.setGutterShown(gutter) { [weak self] gutter in
                gutter.lineNumber = { self?.index.lineNumber(startingAt: $0) }
                gutter.lastLineNumber = { self?.index.lineCount ?? 1 }
            }
        }

        private func install(_ document: NoteEditorDocument, in view: NoteSourceTextView) {
            isInstalling = true
            index = document.index
            view.attributedText = document.attributed
            view.typingAttributes = NoteEditorTheme.baseAttributes()
            isInstalling = false
            dirty = nil
            repaintWorkItem?.cancel()
        }

        /// Lay the whole note out, a slice per main-thread tick so the screen keeps moving. Once
        /// this has run every line fragment is measured, and an edit only moves what follows it.
        /// Answers false when a newer load replaced this one.
        ///
        /// Waits for a width: layout at the zero width a view has before SwiftUI sizes it would be
        /// thrown away entire.
        private func settleLayout(of view: NoteSourceTextView, token: Int) async -> Bool {
            while view.bounds.width == 0 {
                try? await Task.sleep(for: .milliseconds(16))
                guard token == loadToken else { return false }
            }
            let length = view.textStorage.length
            var laidOut = 0
            while laidOut < length {
                let started = DispatchTime.now()
                while laidOut < length, DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds < 8_000_000 {
                    let slice = min(4_000, length - laidOut)
                    view.layoutManager.ensureLayout(
                        forCharacterRange: NSRange(location: laidOut, length: slice))
                    laidOut += slice
                }
                try? await Task.sleep(for: .milliseconds(1))
                guard token == loadToken else { return false }
            }
            return true
        }

        private func finishLoading(_ view: NoteSourceTextView) {
            isLoaded = true
            view.isEditable = true
            view.alpha = 1
            restoreOffset(of: view)
            applyRequests(in: view)
        }

        private func restoreOffset(of view: NoteSourceTextView) {
            let wanted = parent.handle.offsetY
            guard wanted > 0, view.bounds.height > 0 else { return }
            view.layoutIfNeeded()
            let lowest = max(view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom, 0)
            view.contentOffset.y = min(wanted, lowest)
        }

        /// The body changed from outside. Text typed in the last moments wins over a reload it
        /// raced, because the store's conflict rules can only protect a draft they have been told
        /// about: publishing it lets them decide.
        func adoptExternalBody(in view: NoteSourceTextView) {
            guard publishWorkItem == nil else {
                DispatchQueue.main.async { [weak self] in self?.publishNow() }
                return
            }
            let body = parent.text()
            guard view.nativeText != body else { return }
            load(body, into: view)
            DispatchQueue.main.async { [weak self] in self?.parent.onReplaced() }
        }

        /// What the view asked for that needs a finished document: focus, a jump, an insertion, a
        /// search highlight.
        func applyRequests(in view: NoteSourceTextView) {
            guard isLoaded else { return }
            applyHighlight(in: view)

            // `isFocused` drives first-responder status in both directions, not only upwards: a
            // sheet covering this view (see `NoteEditorSurface/isCoveredBySheet`) makes it false
            // regardless of whether the reader was mid-keystroke, and this is what actually lets
            // go of the keyboard rather than merely skipping the next reclaim — a view that
            // already is first responder stays one under an `if isFocused` with no `else`, sheet
            // or not.
            if parent.isFocused {
                // Not while the link form is up: it holds the keyboard, and reclaiming it here
                // would pull the keyboard out from under the form's own fields.
                if !view.isFirstResponder, !isPresentingLinkForm { view.becomeFirstResponder() }
            } else if view.isFirstResponder {
                view.resignFirstResponder()
            }

            if let insertion = parent.insertion, insertion.token != appliedInsertionToken {
                appliedInsertionToken = insertion.token
                let at = min(max(insertion.offset, 0), view.textStorage.length)
                apply(
                    MarkdownEdit(
                        range: NSRange(location: at, length: 0), replacement: insertion.snippet,
                        selection: NSRange(location: at + insertion.snippet.utf16.count, length: 0)),
                    to: view)
            }

            if let caret = parent.caret, caret.token != appliedCaretToken {
                appliedCaretToken = caret.token
                let clamped = min(max(caret.offset, 0), view.textStorage.length)
                view.selectedRange = NSRange(location: clamped, length: 0)
                bringCaretIntoView(view, settlingAtTopThird: caret.settlesAtTopThird)
            }
        }

        // MARK: Editing

        func textViewDidChange(_ textView: UITextView) {
            scheduleRepaint()
            schedulePublish()
        }

        /// The one place every change of the text passes through, typing, Undo, dictation and
        /// paste alike. Attribute edits are the repaint's own and leave the index alone.
        nonisolated func textStorage(
            _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
            range editedRange: NSRange, changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            nonisolated(unsafe) let storage = textStorage
            MainActor.assumeIsolated {
                textChanged(in: storage, editedRange: editedRange, delta: delta)
            }
        }

        private func textChanged(in storage: NSTextStorage, editedRange: NSRange, delta: Int) {
            guard !isInstalling else { return }
            let changed = index.applyEdit(editedRange: editedRange, delta: delta, in: storage.mutableString)
            if let pending = dirty {
                let lowered =
                    pending.upperBound > editedRange.location ? pending.upperBound + delta : pending.upperBound
                let start = min(pending.location, changed.location)
                dirty = NSRange(location: start, length: max(lowered, changed.upperBound) - start)
            } else {
                dirty = changed
            }
            textView?.gutter?.setNeedsDisplay()
            textView?.highlightLayer.textChanged(editedRange: editedRange, delta: delta)
        }

        /// Coalesces a typing burst into one repaint of the lines it touched. A repaint running
        /// inside marked text would end the composition under the reader, so it waits that out.
        private func scheduleRepaint() {
            repaintWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.repaintDirtyLines() }
            repaintWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.repaintDebounce, execute: work)
        }

        private func repaintDirtyLines() {
            guard let textView, let pending = dirty else { return }
            guard textView.markedTextRange == nil else {
                scheduleRepaint()
                return
            }
            let storage = textView.textStorage
            let upperBound = min(pending.upperBound, storage.length)
            let firstLine = index.line(containing: min(pending.location, storage.length))
            let start = index.lineStarts[firstLine]
            var line = index.line(containing: min(start + Self.repaintSlice, max(upperBound - 1, start)))
            if index.rangeOfLine(line).upperBound < upperBound, line == firstLine { line += 1 }
            let end = index.rangeOfLine(line).upperBound
            let slice = NSRange(location: start, length: end - start)

            #if DEBUG
                let started = DispatchTime.now()
            #endif
            storage.beginEditing()
            NoteEditorTheme.paint(
                storage, in: slice, index: index, text: storage.mutableString,
                showsHangingIndent: parent.showsLineNumbers)
            storage.endEditing()
            // Filled in at once, so no line in the note stands at an estimated height.
            textView.layoutManager.ensureLayout(forCharacterRange: slice)
            #if DEBUG
                benchRepaintsMs.append(NoteEditorBench.milliseconds(since: started))
            #endif

            if end < upperBound {
                dirty = NSRange(location: end, length: upperBound - end)
                DispatchQueue.main.async { [weak self] in self?.repaintDirtyLines() }
            } else {
                dirty = nil
            }
        }

        var hasRepaintPending: Bool { dirty != nil }

        private func schedulePublish() {
            publishWorkItem?.cancel()
            let now = DispatchTime.now()
            let first = firstUnpublishedEdit ?? now
            firstUnpublishedEdit = first
            let work = DispatchWorkItem { [weak self] in self?.publishNow() }
            publishWorkItem = work
            let due = min(now + Self.publishPause, first + Self.publishLimit)
            DispatchQueue.main.asyncAfter(deadline: due, execute: work)
        }

        /// Copying the text out is the one step here that scales with the note, which is why it
        /// runs on a timer and not per key.
        func publishNow() {
            guard let work = publishWorkItem, let textView else { return }
            work.cancel()
            publishWorkItem = nil
            firstUnpublishedEdit = nil
            #if DEBUG
                let started = DispatchTime.now()
            #endif
            parent.onChange(textView.nativeText)
            #if DEBUG
                benchPublishesMs.append(NoteEditorBench.milliseconds(since: started))
            #endif
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocus()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            keyboardBar.setShowsFormatting(!isInsideFence(textView.selectedRange.location))
        }

        private func isInsideFence(_ offset: Int) -> Bool {
            index.isInsideFence(min(offset, index.length))
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.handle.offsetY = scrollView.contentOffset.y
        }

        // MARK: Geometry

        /// A narrower view (the keyboard arriving) must keep the caret in sight, and a change of
        /// width reflows every line, whose new heights are measured the way the first ones were.
        private func boundsChanged(_ view: NoteSourceTextView, from oldSize: CGSize) {
            if oldSize == .zero, isLoaded { restoreOffset(of: view) }
            if oldSize.height > view.bounds.height, view.isFirstResponder {
                DispatchQueue.main.async { [weak view] in
                    guard let view else { return }
                    view.scrollRangeToVisible(view.selectedRange)
                }
            }
            guard isLoaded, oldSize.width > 0, oldSize.width != view.bounds.width,
                view.textStorage.length > MarkdownSourceTextView.backgroundLoadLength
            else { return }
            let layoutManager = view.layoutManager
            let top = layoutManager.characterIndex(
                for: CGPoint(x: 0, y: view.contentOffset.y), in: view.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)
            let token = loadToken
            Task { [weak self, weak view] in
                guard let self, let view, await self.settleLayout(of: view, token: token) else { return }
                // The reader's line stays at the top of the screen, whatever the reflow above it
                // added or removed.
                let glyph = layoutManager.glyphIndexForCharacter(at: top)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                view.layoutIfNeeded()
                view.contentOffset.y = fragment.minY
            }
        }

        // MARK: Highlight

        /// Painted by a layer behind the text rather than as attributes of it: no character,
        /// attribute run or line height changes, so a search over a large note moves nothing and
        /// costs no layout.
        private func applyHighlight(in view: NoteSourceTextView) {
            let query = parent.highlight
            guard query != paintedHighlight else { return }
            paintedHighlight = query
            highlightToken += 1
            let token = highlightToken
            view.highlightLayer.matches = []
            guard let query, !query.isEmpty else { return }
            let text = view.nativeText
            Task { [weak self] in
                let matches = await Task.detached(priority: .userInitiated) {
                    SearchText.findMatches(in: text, query: query)
                }.value
                guard let self, token == self.highlightToken else { return }
                view.highlightLayer.matches = matches
            }
        }

        /// Return inside a list carries the marker down, and the indentation with it.
        ///
        /// Done here rather than after the fact because the newline must not be inserted first:
        /// reacting to it would put the marker on screen one frame late, and undoing it would take
        /// two presses of Undo to get back to where the reader was.
        func textView(
            _ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
        ) -> Bool {
            guard text == "\n", !isInsideFence(range.location), let view = self.textView else { return true }
            // The marker is all on the caret's own line, so that line is all this reads.
            let line = index.rangeOfLine(index.line(containing: range.location))
            guard
                let continuation = MarkdownListContinuation.onReturn(
                    text: textView.textStorage.mutableString.substring(with: line),
                    caretUtf16: range.location - line.location)
            else { return true }
            let target = NSRange(
                location: range.location - continuation.deleteBefore,
                length: range.length + continuation.deleteBefore)
            guard target.location >= 0 else { return true }
            apply(
                MarkdownEdit(
                    range: target, replacement: continuation.insert,
                    selection: NSRange(
                        location: target.location + continuation.insert.utf16.count, length: 0)),
                to: view)
            return false
        }

        // MARK: The keyboard bar

        private func handle(_ item: NoteEditorBarItem) {
            guard let textView else { return }
            switch item {
            case .dismissKeyboard:
                textView.resignFirstResponder()
            case .attach:
                parent.onAttach(textView.selectedRange.location)
            case .link:
                guard !isInsideFence(textView.selectedRange.location) else { return }
                presentLinkForm(for: textView)
            case .undo:
                textView.undoManager?.undo()
            case .redo:
                textView.undoManager?.redo()
            case .command(let command):
                guard !isInsideFence(textView.selectedRange.location) else { return }
                let source = textView.text ?? ""
                guard let edit = MarkdownEditing.edit(command, in: source, selection: textView.selectedRange)
                else { return }
                apply(edit, to: textView)
            }
        }

        /// The link button's form: a name and an address, prefilled from the selection (see
        /// ``MarkdownLinkEditing/draft(in:selection:)``). A UIKit alert rather than a SwiftUI sheet
        /// because it opens with the keyboard already up and has to hand it straight back: OK
        /// writes the link through ``apply(_:to:)`` — so Undo takes back just the link — and leaves
        /// the caret after it, Cancel restores the selection it found, and Remove link (offered on an
        /// existing markdown link only) replaces it with its plain label.
        private func presentLinkForm(for textView: NoteSourceTextView) {
            guard !isPresentingLinkForm, var presenter = textView.window?.rootViewController else { return }
            while let next = presenter.presentedViewController { presenter = next }
            let selection = textView.selectedRange
            let draft = MarkdownLinkEditing.draft(in: textView.text ?? "", selection: selection)

            let alert = UIAlertController(title: "Link", message: nil, preferredStyle: .alert)
            alert.addTextField { field in
                field.placeholder = "Name"
                field.text = draft.text
                field.autocapitalizationType = .sentences
                field.clearButtonMode = .whileEditing
            }
            alert.addTextField { field in
                field.placeholder = "URL"
                field.text = draft.url
                field.keyboardType = .URL
                field.textContentType = .URL
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
                field.clearButtonMode = .whileEditing
            }
            let ok = UIAlertAction(title: "OK", style: .default) { [weak self, weak alert, weak textView] _ in
                guard let self, let textView else { return }
                let edit = MarkdownLinkEditing.edit(
                    replacing: draft, text: alert?.textFields?.first?.text ?? "",
                    url: alert?.textFields?.last?.text ?? "")
                self.finishLinkForm(in: textView, selection: selection, edit: edit)
            }
            let cancel = UIAlertAction(title: "Cancel", style: .cancel) { [weak self, weak textView] _ in
                guard let self, let textView else { return }
                self.finishLinkForm(in: textView, selection: selection, edit: nil)
            }
            alert.addAction(cancel)
            // Only on an existing `[text](url)`: a bare URL or a new link has nothing to remove.
            if let unlink = MarkdownLinkEditing.unlinkEdit(replacing: draft, in: textView.text ?? "") {
                alert.addAction(
                    UIAlertAction(title: "Remove link", style: .destructive) { [weak self, weak textView] _ in
                        guard let self, let textView else { return }
                        self.finishLinkForm(in: textView, selection: selection, edit: unlink)
                    })
            }
            alert.addAction(ok)
            alert.preferredAction = ok
            ok.isEnabled = MarkdownLinkEditing.hasAddress(draft.url)
            if let urlField = alert.textFields?.last {
                urlField.addAction(
                    UIAction { [weak ok, weak urlField] _ in
                        ok?.isEnabled = MarkdownLinkEditing.hasAddress(urlField?.text)
                    }, for: .editingChanged)
            }
            isPresentingLinkForm = true
            presenter.present(alert, animated: true)
        }

        private func finishLinkForm(in textView: NoteSourceTextView, selection: NSRange, edit: MarkdownEdit?) {
            isPresentingLinkForm = false
            textView.becomeFirstResponder()
            textView.selectedRange = selection
            if let edit { apply(edit, to: textView) }
        }

        /// Put an edit through the text view's own editing path rather than assigning its text.
        ///
        /// Assigning replaces the whole string, which UIKit records as one wholesale change: Undo
        /// after a formatting button would then discard the paragraph rather than the formatting.
        private func apply(_ edit: MarkdownEdit, to textView: NoteSourceTextView) {
            guard
                let start = textView.position(from: textView.beginningOfDocument, offset: edit.range.location),
                let end = textView.position(from: start, offset: edit.range.length),
                let range = textView.textRange(from: start, to: end)
            else { return }
            textView.replace(range, withText: edit.replacement)
            textView.selectedRange = edit.selection
            // Called explicitly: a programmatic replace not reaching the delegate would leave the
            // note on screen and the note on disk disagreeing, with nothing to notice it. Reaching
            // it twice is harmless, since both steps coalesce.
            textViewDidChange(textView)
        }

        /// Bring the caret into view after something outside the keyboard moved it. Typing needs
        /// none of this: a scrolling text view keeps its own insertion point visible.
        ///
        /// `settlingAtTopThird` is for an arrival rather than a keystroke — a heading tapped in the
        /// outline, a search hit. Scrolling by the minimum leaves the target flush against the
        /// navigation bar, or already on screen and apparently unmoved; a third of the way down is
        /// where a reader looks for the thing they just asked for.
        ///
        /// Deferred so the view has taken any height change the same update brought, since the
        /// offset depends on the height at the moment of scrolling.
        func bringCaretIntoView(_ view: NoteSourceTextView, settlingAtTopThird: Bool) {
            DispatchQueue.main.async { [weak view] in
                guard let view, let selection = view.selectedTextRange else { return }
                view.layoutIfNeeded()
                let caret = view.caretRect(for: selection.end)
                guard !caret.isNull, !caret.isInfinite else { return }
                // Padded so the caret does not sit flush against the keyboard or the navigation
                // bar, which reads as clipped even when every pixel of it is on screen.
                guard settlingAtTopThird else {
                    view.scrollRectToVisible(caret.insetBy(dx: 0, dy: -24), animated: false)
                    return
                }
                let insets = view.adjustedContentInset
                let visible = view.bounds.height - insets.top - insets.bottom
                let highest = -insets.top
                let lowest = max(view.contentSize.height - visible - insets.top, highest)
                let wanted = caret.minY - visible / 3 - insets.top
                // One immediate write: an animation across a long note is a stream of positions
                // the reader never asked to pass through.
                view.setContentOffset(CGPoint(x: 0, y: min(max(wanted, highest), lowest)), animated: false)
            }
        }
    }
}

/// The editor's text view: the composer's paste handling, the pinned gutter and search highlight,
/// and word of its own size changing.
final class NoteSourceTextView: PasteAwareTextView {
    private(set) var gutter: NoteLineNumberGutter?
    private(set) lazy var highlightLayer: NoteSearchHighlightLayer = {
        let layer = NoteSearchHighlightLayer(frame: .zero)
        layer.textView = self
        insertSubview(layer, at: 0)
        return layer
    }()
    /// Called after a layout pass that changed the view's size, with the size before it.
    var onBoundsChange: ((NoteSourceTextView, CGSize) -> Void)?
    private var lastSize = CGSize.zero

    /// The text as a native Swift string. `text` hands back a Cocoa-backed one, and comparing or
    /// walking that goes through the Objective-C runtime a code unit at a time, which on a large
    /// note is hundreds of milliseconds wherever it lands.
    var nativeText: String {
        var native = text ?? ""
        native.makeContiguousUTF8()
        return native
    }
    private var lastPinnedOffset = CGFloat.nan

    func setGutterShown(_ shown: Bool, configure: (NoteLineNumberGutter) -> Void) {
        guard shown else {
            gutter?.removeFromSuperview()
            gutter = nil
            return
        }
        guard gutter == nil else { return }
        let view = NoteLineNumberGutter(frame: .zero)
        view.textView = self
        configure(view)
        addSubview(view)
        gutter = view
    }

    /// A scroll view lays itself out on every change of its offset, so this is also what keeps
    /// the gutter pinned over the visible area.
    override func layoutSubviews() {
        super.layoutSubviews()
        highlightLayer.frame = bounds
        if let gutter {
            gutter.frame = CGRect(x: 0, y: bounds.minY, width: textContainerInset.left, height: bounds.height)
            bringSubviewToFront(gutter)
        }
        if bounds.minY != lastPinnedOffset {
            lastPinnedOffset = bounds.minY
            gutter?.setNeedsDisplay()
            highlightLayer.setNeedsDisplay()
        }
        if bounds.size != lastSize {
            let old = lastSize
            lastSize = bounds.size
            onBoundsChange?(self, old)
        }
    }
}
