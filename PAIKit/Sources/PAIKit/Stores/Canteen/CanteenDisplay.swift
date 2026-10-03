import Foundation

/// What the Canteen screen shows, as values — the Swift side of `canteenModel.ts`, so the same
/// decisions are proven on Linux rather than read out of a view.
public enum CanteenDisplay {

    /// How a PDF is labelled on its chip: the language when known, else the file's own name.
    public static func attachmentLabel(_ attachment: CanteenAttachment) -> String {
        switch attachment.language {
        case "de": return "Deutsch"
        case "en": return "English"
        default: return attachment.filename
        }
    }

    /// An allergen flag a vegetarian meal shows.
    public struct Flag: Equatable, Sendable {
        public let code: String
        public let label: String
    }

    /// The flags a meal shows, in display order. A vegan meal never shows any: its codes are
    /// unreliable, and the reader checks its ingredients instead.
    public static func flags(_ meal: CanteenMeal) -> [Flag] {
        guard meal.kind == .vegetarian else { return [] }
        var flags: [Flag] = []
        if meal.milk == true { flags.append(Flag(code: "G", label: "Milk")) }
        if meal.egg == true { flags.append(Flag(code: "C", label: "Egg")) }
        return flags
    }

    /// A day's heading: the German header as printed, else the English one, else the ISO date.
    public static func dayTitle(_ day: CanteenDay) -> String {
        day.labelDe ?? day.labelEn ?? day.date ?? ""
    }

    /// First and last dated day of the menu, `nil` when none carries a date.
    public static func menuSpan(_ entry: CanteenEntry) -> (from: String, to: String)? {
        let dates = (entry.menu?.days ?? []).compactMap(\.date).sorted()
        guard let first = dates.first, let last = dates.last else { return nil }
        return (first, last)
    }

    /// What an entry's menu section has to say.
    public enum MenuState: Equatable, Sendable {
        case parsed
        /// PDFs are attached but none could be read.
        case unparsed
        case noPdfs
    }

    public static func menuState(_ entry: CanteenEntry) -> MenuState {
        if entry.menu != nil { return .parsed }
        return entry.attachments.isEmpty ? .noPdfs : .unparsed
    }
}
