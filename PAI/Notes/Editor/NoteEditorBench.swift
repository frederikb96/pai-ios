#if DEBUG
    import PAIKit
    import UIKit

    /// Measures the editor on screen through its real text view, for `POST /notes/editor-bench`.
    ///
    /// Keystrokes go through `insertText`, the path the keyboard uses, so the numbers include the
    /// delegate calls, the index update and the layout they cause. A paced typist leaves room for
    /// the repaint and the publish, which are reported on their own because they run off the
    /// keystroke.
    @MainActor
    enum NoteEditorBench {
        static weak var coordinator: MarkdownSourceTextView.Coordinator?

        nonisolated static func milliseconds(since start: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        }

        struct Timing: Encodable, Sendable {
            let count: Int
            let p50: Double
            let p95: Double
            let max: Double

            init(_ samples: [Double]) {
                let sorted = samples.sorted()
                count = sorted.count
                p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count) * 0.95)]
                max = sorted.last ?? 0
            }
        }

        struct Report: Encodable, Sendable {
            let utf16Length: Int
            let lineCount: Int
            let width: Double
            let loadMs: Double?
            let keystrokeMs: Timing
            /// The longest the main thread answered nothing, with the editor idle, while typing,
            /// and in the seconds after typing stops, when the autosave runs.
            let idleMainStallMs: Double
            let typingMainStallMs: Double
            let autosaveMainStallMs: Double
            let repaintMs: Timing
            let publishMs: Timing
            /// Opening a fence restyles everything below it, a slice per tick.
            let fenceRepaintTotalMs: Double
            let fenceRepaintLongestSliceMs: Double
            /// Where a jump to the last heading put it, as a fraction of the visible height.
            let lastHeadingViewportFraction: Double
            let contentHeightAtOpen: Double
            let contentHeightAfterVisitingEnd: Double
            let usedHeight: Double
            let undoRestoredText: Bool
        }

        static func run(keys: Int, lineNumbers: Bool) async -> Report? {
            AppEnvironment.shared.connection?.settings.setShowsNoteLineNumbers(lineNumbers)
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<1500 where !(coordinator?.isLoaded ?? false) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard let coordinator, coordinator.isLoaded, let view = coordinator.benchTextView else { return nil }
            coordinator.benchRepaintsMs = []
            coordinator.benchPublishesMs = []
            let storage = view.textStorage
            let contentHeightAtOpen = view.contentSize.height

            view.becomeFirstResponder()
            view.selectedRange = NSRange(location: storage.length / 2, length: 0)
            view.scrollRangeToVisible(view.selectedRange)
            try? await Task.sleep(for: .milliseconds(600))

            let idle = MainStallRecorder()
            try? await Task.sleep(for: .seconds(2))
            let idleMainStall = idle.finish()

            let typing = MainStallRecorder()
            var keystrokes: [Double] = []
            for key in 0..<keys {
                let started = DispatchTime.now()
                view.insertText(key % 12 == 11 ? "\n" : "x")
                view.layoutIfNeeded()
                keystrokes.append(milliseconds(since: started))
                // A fast typist, with a pause now and then for the repaint to run.
                try? await Task.sleep(for: .milliseconds(key % 16 == 15 ? 250 : 70))
            }
            let typingMainStall = typing.finish()
            let afterTyping = MainStallRecorder()
            try? await Task.sleep(for: .seconds(3))
            let autosaveMainStall = afterTyping.finish()
            let repaints = coordinator.benchRepaintsMs
            let publishes = coordinator.benchPublishesMs

            coordinator.benchRepaintsMs = []
            let lineStart = coordinator.index.lineStarts[coordinator.index.line(containing: storage.length / 4)]
            view.selectedRange = NSRange(location: lineStart, length: 0)
            view.insertText("```\n")
            while coordinator.hasRepaintPending { try? await Task.sleep(for: .milliseconds(5)) }
            let fenceRepaints = coordinator.benchRepaintsMs
            let afterFence = view.text
            view.deleteBackward()
            view.undoManager?.undo()
            let undoRestoredText = view.text == afterFence

            let source = storage.mutableString
            let lastHeading = source.range(of: "\n## ", options: .backwards).location + 1
            view.selectedRange = NSRange(location: lastHeading, length: 0)
            coordinator.bringCaretIntoView(view, settlingAtTopThird: true)
            try? await Task.sleep(for: .milliseconds(200))
            let insets = view.adjustedContentInset
            let visible = view.bounds.height - insets.top - insets.bottom
            let caret = view.selectedTextRange.map { view.caretRect(for: $0.end) } ?? .null
            let fraction = (caret.minY - view.contentOffset.y - insets.top) / visible

            return Report(
                utf16Length: storage.length, lineCount: coordinator.index.lineCount, width: view.bounds.width,
                loadMs: coordinator.benchLoadMs, keystrokeMs: Timing(keystrokes), idleMainStallMs: idleMainStall,
                typingMainStallMs: typingMainStall, autosaveMainStallMs: autosaveMainStall,
                repaintMs: Timing(repaints), publishMs: Timing(publishes),
                fenceRepaintTotalMs: fenceRepaints.reduce(0, +), fenceRepaintLongestSliceMs: fenceRepaints.max() ?? 0,
                lastHeadingViewportFraction: fraction, contentHeightAtOpen: contentHeightAtOpen,
                contentHeightAfterVisitingEnd: view.contentSize.height,
                usedHeight: view.layoutManager.usedRect(for: view.textContainer).height,
                undoRestoredText: undoRestoredText)
        }
    }

    /// The longest gap between ticks of a 4 ms timer on the main queue, which is how long the main
    /// thread could not have answered a key.
    @MainActor
    private final class MainStallRecorder {
        private var timer: DispatchSourceTimer?
        private let box = Box()

        private final class Box: @unchecked Sendable {
            var last = DispatchTime.now()
            var longest: UInt64 = 0
        }

        init() {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: .milliseconds(4))
            timer.setEventHandler { [box] in
                let now = DispatchTime.now()
                box.longest = max(box.longest, now.uptimeNanoseconds - box.last.uptimeNanoseconds)
                box.last = now
            }
            timer.resume()
            self.timer = timer
        }

        func finish() -> Double {
            timer?.cancel()
            timer = nil
            return Double(box.longest) / 1_000_000
        }
    }
#endif
