import Foundation

/// Where a reply's prose card draws one decision: after `position` of its markdown blocks.
public struct DecisionSlot: Hashable, Sendable {
    /// How many of the card's blocks come before it.
    public let position: Int
    public let number: Int

    public init(position: Int, number: Int) {
        self.position = position
        self.number = number
    }
}

/// What one decision place in a reply draws, resolved from the session's decisions.
public enum InlineDecisionDisplay: Hashable, Sendable {
    /// The marker line as the text it is: a guest's transcript, or a number the session never had.
    case marker(number: Int)
    /// The session's decisions are not read yet. Draws nothing and takes no room, so a marker
    /// never flashes up as text before its card replaces it.
    case loading
    /// The card the pin opens to: title, recommendation, context, the answers, and Send.
    case open(InlineOpenDecision)
    /// One line: the title and the answer, or `nil` for a decision that was withdrawn.
    case resolved(number: Int, title: String, answer: String?)
}

/// An open decision as its card shows it right now.
public struct InlineOpenDecision: Hashable, Sendable {
    public let decision: Decision
    /// The answer picked for it, from whichever surface.
    public let picked: String?
    /// How many of the session's picks a Send here would send; the Send bar shows when any.
    public let pendingCount: Int
    public let isSending: Bool
    /// What this card's last Send or Dismiss attempt was refused with.
    public let errorMessage: String?

    public init(decision: Decision, picked: String?, pendingCount: Int, isSending: Bool, errorMessage: String?) {
        self.decision = decision
        self.picked = picked
        self.pendingCount = pendingCount
        self.isSending = isSending
        self.errorMessage = errorMessage
    }
}

/// Everything a transcript pass knows about the session's decisions, resolving each place a reply
/// embeds one.
public struct InlineDecisionContext: Sendable {
    /// Whether this account sees decisions at all (the owner); a guest sees the marker text.
    public let mayDecide: Bool
    /// The session's decisions in every state, `nil` until first read.
    public let listed: [Decision]?
    public let picks: [Int: DecisionPick]
    public let pendingCount: Int
    /// Per decision number: a Send or Dismiss from its card in flight, and its last refusal.
    public let cardStates: [Int: CardState]

    public struct CardState: Hashable, Sendable {
        public let isSending: Bool
        public let errorMessage: String?

        public init(isSending: Bool, errorMessage: String?) {
            self.isSending = isSending
            self.errorMessage = errorMessage
        }
    }

    public init(
        mayDecide: Bool, listed: [Decision]?, picks: [Int: DecisionPick] = [:], pendingCount: Int = 0,
        cardStates: [Int: CardState] = [:]
    ) {
        self.mayDecide = mayDecide
        self.listed = listed
        self.picks = picks
        self.pendingCount = pendingCount
        self.cardStates = cardStates
    }

    public func display(for number: Int) -> InlineDecisionDisplay {
        guard mayDecide else { return .marker(number: number) }
        guard let listed else { return .loading }
        guard let decision = listed.first(where: { $0.number == number }) else { return .marker(number: number) }
        switch decision.state {
        case .open:
            let state = cardStates[number]
            return .open(
                InlineOpenDecision(
                    decision: decision, picked: picks[number]?.text, pendingCount: pendingCount,
                    isSending: state?.isSending ?? false, errorMessage: state?.errorMessage))
        case .answered:
            return .resolved(number: number, title: decision.title, answer: decision.answer ?? "")
        case .withdrawn, .unrecognized:
            return .resolved(number: number, title: decision.title, answer: nil)
        }
    }
}

/// The geometry of an inline decision card, kept here so the height a row reserves and the view
/// in `PAI/` that draws the card read the same numbers. Every text in the card is a markdown
/// paragraph measured by the transcript's own measurer and drawn by its own markdown view, and the
/// view pins each section to the height measured here, so the card cannot disagree with its row.
public enum InlineDecisionLayout {

    // MARK: - Chrome

    public static let cardHorizontalPadding: Double = 12
    public static let cardVerticalPadding: Double = 10
    /// The gap between the card's sections (title, recommendation, chips, context, answers, Send).
    public static let sectionSpacing: Double = 8
    /// A resolved decision's one line, inside its own border.
    public static let resolvedVerticalPadding: Double = 8
    /// The chips beside an open decision (blocks, the pick) sit on one caption line with this
    /// padding above and below.
    public static let chipVerticalPadding: Double = 2
    public static let optionColumnSpacing: Double = 8
    public static let optionRowSpacing: Double = 8
    public static let optionHorizontalPadding: Double = 10
    public static let optionVerticalPadding: Double = 8
    /// The Send bar is one line of prose in a button with this padding above and below.
    public static let sendBarVerticalPadding: Double = 8
    /// Options sit in a grid of this many columns, so every button's width is known before layout.
    public static let optionColumns = 2

    // MARK: - Content

    /// The card's first line: its number in bold, then what a yes sets in motion.
    public static func titleBlock(number: Int, title: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: "D\(number)", style: .bold), InlineRun(text: " \(title)")]))
    }

    public static func recommendationBlock(_ decision: Decision) -> MarkdownBlock {
        paragraph("Recommended: \(decision.recommendation)")
    }

    public static func contextBlocks(_ decision: Decision) -> [MarkdownBlock] {
        decision.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : MarkdownParser.parse(decision.context)
    }

    /// One button of the answer grid, in order: each option, Other… for own words, Dismiss.
    public enum Answer: Hashable, Sendable {
        case option(String)
        case ownWords
        case dismiss
    }

    public static func answers(_ decision: Decision) -> [Answer] {
        decision.options.map(Answer.option) + [.ownWords, .dismiss]
    }

    public static func label(of answer: Answer, in decision: Decision) -> String {
        switch answer {
        case .option(let option): decision.isRecommended(option) ? "\(option) (recommended)" : option
        case .ownWords: "Other…"
        case .dismiss: "Dismiss"
        }
    }

    /// Whether the chip line shows: the decision blocks the agent, or an answer is picked.
    public static func showsChips(_ open: InlineOpenDecision) -> Bool {
        open.decision.blocks || open.picked != nil
    }

    /// A resolved decision's line: number and title, then the answer or that it was withdrawn.
    public static func resolvedBlock(number: Int, title: String, answer: String?) -> MarkdownBlock {
        .paragraph(
            InlineText(runs: [
                InlineRun(text: "D\(number)", style: .bold),
                InlineRun(text: " \(title)"),
                InlineRun(text: answer.map { " — answered: \($0)" } ?? " — withdrawn"),
            ]))
    }

    public static func markerBlock(number: Int) -> MarkdownBlock {
        paragraph("{{D\(number)}}")
    }

    public static func errorBlock(_ message: String) -> MarkdownBlock {
        paragraph(message)
    }

    private static func paragraph(_ text: String) -> MarkdownBlock {
        .paragraph(InlineText(runs: [InlineRun(text: text)]))
    }

    // MARK: - Measurement

    /// One card, measured: its total height and each section's, for the view to pin.
    public struct Measured: Hashable, Sendable {
        public let height: Double
        public let title: Double
        public let recommendation: Double
        /// `0` when the chip line is not drawn.
        public let chips: Double
        /// `0` when the decision has no context.
        public let context: Double
        /// One height per row of the answer grid.
        public let answerRows: [Double]
        /// `0` when the Send bar is not drawn.
        public let sendBar: Double
        /// `0` when there is no refusal to show.
        public let error: Double

        public static let zero = Measured(
            height: 0, title: 0, recommendation: 0, chips: 0, context: 0, answerRows: [], sendBar: 0, error: 0)

        public init(
            height: Double, title: Double, recommendation: Double, chips: Double, context: Double,
            answerRows: [Double], sendBar: Double, error: Double
        ) {
            self.height = height
            self.title = title
            self.recommendation = recommendation
            self.chips = chips
            self.context = context
            self.answerRows = answerRows
            self.sendBar = sendBar
            self.error = error
        }

        static func single(_ height: Double) -> Measured {
            Measured(
                height: height, title: 0, recommendation: 0, chips: 0, context: 0, answerRows: [], sendBar: 0,
                error: 0)
        }
    }

    /// The width a card's text wraps at, inside its padding.
    public static func innerWidth(cardWidth: Double) -> Double {
        max(0, cardWidth - 2 * cardHorizontalPadding)
    }

    /// The width one answer's label wraps at, inside its button.
    public static func answerLabelWidth(cardWidth: Double) -> Double {
        let columns = Double(optionColumns)
        let column = (innerWidth(cardWidth: cardWidth) - optionColumnSpacing * (columns - 1)) / columns
        return max(0, column - 2 * optionHorizontalPadding)
    }

    public static func measure(
        _ display: InlineDecisionDisplay, width: Double, environment: MeasurementEnvironment,
        metrics: MessageLayoutMetrics, measurer: some BlockMeasuring, cache: BlockHeightCache
    ) -> Measured {
        func height(_ block: MarkdownBlock, at width: Double) -> Double {
            cache.height(of: block, width: width, environment: environment, measurer: measurer)
        }

        switch display {
        case .loading:
            return .zero

        case .marker(let number):
            return .single(height(markerBlock(number: number), at: width))

        case .resolved(let number, let title, let answer):
            let line = height(
                resolvedBlock(number: number, title: title, answer: answer), at: innerWidth(cardWidth: width))
            return .single(line + 2 * resolvedVerticalPadding)

        case .open(let open):
            let inner = innerWidth(cardWidth: width)
            let decision = open.decision
            let title = height(titleBlock(number: decision.number, title: decision.title), at: inner)
            let recommendation = height(recommendationBlock(decision), at: inner)
            let chips = showsChips(open) ? metrics.trailerLineHeight + 2 * chipVerticalPadding : 0
            let context =
                MessageContentLayoutComposer.layout(
                    of: contextBlocks(decision), width: inner, environment: environment, metrics: metrics,
                    measurer: measurer, cache: cache
                ).totalHeight

            let labelWidth = answerLabelWidth(cardWidth: width)
            let buttons = answers(decision).map { answer in
                height(paragraph(label(of: answer, in: decision)), at: labelWidth) + 2 * optionVerticalPadding
            }
            var answerRows: [Double] = []
            var index = 0
            while index < buttons.count {
                let row = buttons[index..<min(index + optionColumns, buttons.count)]
                answerRows.append(row.max() ?? 0)
                index += optionColumns
            }
            let grid =
                answerRows.reduce(0, +) + optionRowSpacing * Double(max(0, answerRows.count - 1))

            let sendBar = open.pendingCount > 0 ? metrics.proseLineHeight + 2 * sendBarVerticalPadding : 0
            let error = open.errorMessage.map { height(errorBlock($0), at: inner) } ?? 0

            let sections = [title, recommendation, chips, context, grid, sendBar, error].filter { $0 > 0 }
            let total =
                sections.reduce(0, +) + sectionSpacing * Double(max(0, sections.count - 1))
                + 2 * cardVerticalPadding
            return Measured(
                height: total, title: title, recommendation: recommendation, chips: chips, context: context,
                answerRows: answerRows, sendBar: sendBar, error: error)
        }
    }
}
