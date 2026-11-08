import XCTest

@testable import PAIKit

/// Math in a reply: what becomes a formula, what must stay the text it was, and that the LaTeX
/// reaches the typesetter as written rather than as markdown rewrote it.
final class MarkdownMathTests: XCTestCase {

    private func formulas(in blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .math(let latex): return ["display:" + latex]
            case .paragraph(let text), .heading(_, let text):
                return text.runs.filter { $0.style.contains(.math) }.map { "inline:" + $0.text }
            case .list(let list): return list.items.flatMap { formulas(in: $0.blocks) }
            case .blockQuote(let nested): return formulas(in: nested)
            default: return []
            }
        }
    }

    /// A reply about money is the commonest text with dollar signs in it, and none of it is math.
    func testPricesStayText() {
        let source = "It costs $5 and $10, or $5-$10 a month; US$3.50/$4 at most, 5 $ in cash."
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(formulas(in: blocks), [])
        XCTAssertEqual(blocks.plainText, source)
    }

    /// The reason formulas are taken out before markdown parses: escapes, emphasis characters and
    /// line breaks in LaTeX would otherwise reach the typesetter rewritten.
    func testFormulasReachTheTypesetterAsWritten() {
        let source = #"Energy $E=mc^2$, a set \(\{x \mid x>0\}\) and $a*b*c$ next to $5."#
        XCTAssertEqual(
            formulas(in: MarkdownParser.parse(source)),
            ["inline:E=mc^2", #"inline:\{x \mid x>0\}"#, "inline:a*b*c"])
    }

    /// Code shows the characters as written, formula delimiters included — also a code span
    /// running across a line break, which the line-by-line scan cannot see as one.
    func testMathInCodeStaysCode() {
        let source = """
            Run `echo $HOME$` or `$x$` or `printf
            $y$`.

            ```
            $$
            \\frac{a}{b}
            $$
            ```
            """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(formulas(in: blocks), [])
        guard case .paragraph(let text) = blocks.first, case .codeBlock(_, let code) = blocks.last else {
            return XCTFail("expected a paragraph and a code block: \(blocks)")
        }
        XCTAssertEqual(
            text.runs.filter { $0.style.contains(.code) }.map(\.text), ["echo $HOME$", "$x$", "printf $y$"])
        XCTAssertEqual(code, "$$\n\\frac{a}{b}\n$$")
    }

    /// A display formula is a block of its own, also when it sits inside a paragraph with no
    /// blank line around it, and its text on either side stays the paragraphs it was.
    func testADisplayFormulaIsABlockBetweenTheTextAroundIt() {
        let source = """
            Before
            $$
            \\sum_{i=1}^n i = \\frac{n(n+1)}{2}
            $$
            after.

            \\[ x^2 \\]
            """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(
            blocks,
            [
                .paragraph(InlineText(runs: [InlineRun(text: "Before")])),
                .math(#"\sum_{i=1}^n i = \frac{n(n+1)}{2}"#),
                .paragraph(InlineText(runs: [InlineRun(text: "after.")])),
                .math("x^2"),
            ])
    }
}
