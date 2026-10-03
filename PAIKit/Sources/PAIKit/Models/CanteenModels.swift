import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts`'s Canteen section (`CanteenEntry`,
/// `CanteenAttachment`, `CanteenMenu`, `CanteenDay`, `CanteenMeal`, `CanteenEntriesResponse`).
/// `pai-cloud` owns this contract; this file mirrors it rather than redefining it.

/// Which diet marker a listed meal carried in the menu PDF. Only marked meals are ever sent.
public enum CanteenMealKind: Sendable, Hashable {
    case vegan, vegetarian
    case unrecognized(String)
}

extension CanteenMealKind: Codable {
    private static let knownValues: [String: CanteenMealKind] = [
        "vegan": .vegan, "vegetarian": .vegetarian,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .vegan: try container.encode("vegan")
        case .vegetarian: try container.encode("vegetarian")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// One PDF of a canteen mail, without its bytes — fetched on demand from
/// `GET /api/canteen/entries/{entry}/attachments/{id}`.
public struct CanteenAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let contentType: String
    public let size: Int
    /// `de` / `en`; `nil` when neither the PDF nor its filename says.
    public let language: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, size, language
        case contentType = "content_type"
    }

    public init(id: String, filename: String, contentType: String, size: Int, language: String?) {
        self.id = id
        self.filename = filename
        self.contentType = contentType
        self.size = size
        self.language = language
    }
}

/// One vegan or vegetarian meal of a day; `number` is its row in the menu (1, 2 or 3).
public struct CanteenMeal: Codable, Sendable, Equatable {
    public let number: Int
    public let kind: CanteenMealKind
    /// Either name is `nil` when only one language's PDF parsed.
    public let nameDe: String?
    public let nameEn: String?
    public let ingredientsDe: [String]
    public let ingredientsEn: [String]
    /// Allergen code G. `nil` on a vegan meal: its codes are unreliable and deliberately not shown.
    public let milk: Bool?
    /// Allergen code C; `nil` on a vegan meal like `milk`.
    public let egg: Bool?

    enum CodingKeys: String, CodingKey {
        case number, kind, milk, egg
        case nameDe = "name_de"
        case nameEn = "name_en"
        case ingredientsDe = "ingredients_de"
        case ingredientsEn = "ingredients_en"
    }

    public init(
        number: Int, kind: CanteenMealKind, nameDe: String?, nameEn: String?,
        ingredientsDe: [String], ingredientsEn: [String], milk: Bool?, egg: Bool?
    ) {
        self.number = number
        self.kind = kind
        self.nameDe = nameDe
        self.nameEn = nameEn
        self.ingredientsDe = ingredientsDe
        self.ingredientsEn = ingredientsEn
        self.milk = milk
        self.egg = egg
    }
}

public struct CanteenDay: Codable, Sendable, Equatable {
    /// ISO date (`2026-09-07`), `nil` when the header carried none.
    public let date: String?
    public let labelDe: String?
    public let labelEn: String?
    public let meals: [CanteenMeal]

    enum CodingKeys: String, CodingKey {
        case date, meals
        case labelDe = "label_de"
        case labelEn = "label_en"
    }

    public init(date: String?, labelDe: String?, labelEn: String?, meals: [CanteenMeal]) {
        self.date = date
        self.labelDe = labelDe
        self.labelEn = labelEn
        self.meals = meals
    }
}

public struct CanteenMenu: Codable, Sendable, Equatable {
    public let days: [CanteenDay]

    public init(days: [CanteenDay]) {
        self.days = days
    }
}

/// One forwarded canteen mail.
public struct CanteenEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let receivedAt: String
    /// First Microsoft Forms link of the mail body, `nil` when there is none.
    public let link: String?
    public let attachments: [CanteenAttachment]
    /// The parsed menu, `nil` when no PDF parsed.
    public let menu: CanteenMenu?
    /// Why `menu` is `nil` although PDFs were present; `nil` otherwise.
    public let menuError: String?

    enum CodingKeys: String, CodingKey {
        case id, link, attachments, menu
        case receivedAt = "received_at"
        case menuError = "menu_error"
    }

    public init(
        id: String, receivedAt: String, link: String?, attachments: [CanteenAttachment],
        menu: CanteenMenu?, menuError: String?
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.link = link
        self.attachments = attachments
        self.menu = menu
        self.menuError = menuError
    }
}

/// `GET /api/canteen/entries` — newest first.
public struct CanteenEntriesResponse: Codable, Sendable, Equatable {
    public let entries: [CanteenEntry]

    public init(entries: [CanteenEntry]) {
        self.entries = entries
    }
}
