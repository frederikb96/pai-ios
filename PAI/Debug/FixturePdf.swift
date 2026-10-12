#if DEBUG
    import UIKit

    /// A small valid PDF for the fixture screenshot of the file viewer, rendered by the system so
    /// PDFKit parses it exactly as it would a fetched one. Two pages with coloured bands and
    /// text, so the screenshot is neither blank nor trivially small and the document scrolls.
    enum FixturePdf {
        static func make() -> Data {
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            let renderer = UIGraphicsPDFRenderer(bounds: bounds)
            return renderer.pdfData { context in
                for page in 1...2 {
                    context.beginPage()
                    for band in 0..<8 {
                        UIColor(hue: CGFloat(band) / 8, saturation: 0.35, brightness: 0.95, alpha: 1).setFill()
                        UIRectFill(CGRect(x: 36, y: 100 + band * 80, width: 540, height: 60))
                    }
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 28), .foregroundColor: UIColor.black,
                    ]
                    "Fixture menu, page \(page)".draw(at: CGPoint(x: 36, y: 40), withAttributes: attributes)
                }
            }
        }
    }
#endif
