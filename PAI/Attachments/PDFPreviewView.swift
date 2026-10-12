import PDFKit
import SwiftUI
import UIKit

/// A PDF as continuous vertical scroll with pinch zoom, fitted to the screen width — PDFKit's own
/// viewer, so text selection, link taps and page rendering come with it.
struct PDFPreviewView: UIViewRepresentable {
    let document: PDFDocument
    /// True while the document sits at its fitted width scrolled to the top — the only state in
    /// which a downward drag should dismiss the viewer rather than scroll or pan the PDF.
    @Binding var isAtRest: Bool

    func makeUIView(context: Context) -> FittedPDFView {
        let view = FittedPDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .black
        let restBinding = $isAtRest
        view.onRestChange = { restBinding.wrappedValue = $0 }
        return view
    }

    /// The document never changes for a presented viewer.
    func updateUIView(_ uiView: FittedPDFView, context: Context) {}
}

/// A `PDFView` that opens fitted to its width, cannot be pinched smaller than that, and reports
/// whether it is at rest. The fit is applied by hand: `autoScales` alone can leave the first frame at
/// the document's natural scale, a page wider than the screen. PDFKit exposes neither the scroll position nor a callback for it, so the scroll view it
/// hosts is found once laid out and its offset observed.
final class FittedPDFView: PDFView {
    var onRestChange: ((Bool) -> Void)?

    private var offsetObservation: NSKeyValueObservation?
    /// The fitted-width scale last applied; `0` until PDFKit can answer with a real one.
    private var appliedFit: CGFloat = 0
    private var lastRest = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleDidChange), name: .PDFViewScaleChanged, object: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyFit()
        observeScrollViewIfNeeded()
        evaluateRest()
    }

    /// Re-fits whenever the fitted scale changes (first layout, rotation) unless the reader has
    /// zoomed in, whose zoom is kept. The zoom range is relative to the fit: down to it, up to
    /// four times it.
    private func applyFit() {
        let fit = scaleFactorForSizeToFit
        guard fit > 0, abs(fit - appliedFit) > 0.001 else { return }
        let wasFitted = appliedFit == 0 || scaleFactor <= appliedFit * 1.01
        appliedFit = fit
        autoScales = false
        minScaleFactor = fit
        maxScaleFactor = fit * 4
        if wasFitted { scaleFactor = fit }
    }

    @objc private func scaleDidChange() {
        evaluateRest()
    }

    private func observeScrollViewIfNeeded() {
        guard offsetObservation == nil, let scrollView = Self.firstScrollView(in: self) else { return }
        offsetObservation = scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.evaluateRest() }
        }
    }

    private func evaluateRest() {
        let fit = scaleFactorForSizeToFit
        let isFitted = fit <= 0 || scaleFactor <= fit * 1.01
        var isAtTop = true
        if let scrollView = Self.firstScrollView(in: self) {
            isAtTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
        }
        let rest = isFitted && isAtTop
        guard rest != lastRest else { return }
        lastRest = rest
        // Deferred: this runs from layout, and writing SwiftUI state during a view update is
        // undefined.
        Task { @MainActor [weak self] in self?.onRestChange?(rest) }
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        for subview in view.subviews {
            if let scrollView = subview as? UIScrollView { return scrollView }
            if let nested = firstScrollView(in: subview) { return nested }
        }
        return nil
    }
}
