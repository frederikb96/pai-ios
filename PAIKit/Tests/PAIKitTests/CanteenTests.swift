import XCTest

@testable import PAIKit

/// The canteen's wire shape (decoded from a payload captured off the backend's own serialiser),
/// the display decisions the screen reads, and the store's load behaviour.
final class CanteenTests: XCTestCase {

    /// `GET /api/canteen/entries` as the backend serialises it: a bare mail first (no link, no
    /// PDFs, `menu` an explicit `null`), then a mail with link, two PDFs and a parsed vegan meal
    /// whose milk/egg flags are `null`.
    private let captured = """
        {"entries": [{"id": "18cc1ccc-417a-4082-b9c0-c7faaaf1739e", "received_at": "2026-10-02T08:13:43+00:00", \
        "link": null, "attachments": [], "menu": null, "menu_error": null}, \
        {"id": "e4a4bb97-c80b-4b7e-a2b4-531ee2da934f", "received_at": "2026-10-02T08:13:43+00:00", \
        "link": "https://forms.cloud.microsoft/Pages/ResponsePage.aspx?id=AAA", "attachments": \
        [{"id": "ec705bd4-6e2c-451f-ad79-be672f987220", "filename": "de.pdf", "content_type": "application/pdf", \
        "size": 1320, "language": "de"}, {"id": "2a1c2cbc-111d-4d12-a4f3-6a4e89d8126d", "filename": "en.pdf", \
        "content_type": "application/pdf", "size": 1320, "language": "en"}], "menu": {"days": [{"date": \
        "2026-09-07", "label_de": "Montag, 7. September 2026", "label_en": "Monday, 7 September 2026", \
        "meals": [{"number": 1, "kind": "vegan", "name_de": "Linsencurry", "name_en": "Lentil Curry", \
        "ingredients_de": ["Linsen"], "ingredients_en": ["Linsen"], "milk": null, "egg": null}]}]}, \
        "menu_error": null}]}
        """

    private func meal(
        kind: CanteenMealKind, milk: Bool?, egg: Bool?
    ) -> CanteenMeal {
        CanteenMeal(
            number: 1, kind: kind, nameDe: "Reispfanne", nameEn: "Rice Pan", ingredientsDe: [],
            ingredientsEn: [], milk: milk, egg: egg)
    }

    private func entry(
        attachments: [CanteenAttachment] = [], menu: CanteenMenu? = nil
    ) -> CanteenEntry {
        CanteenEntry(
            id: "e1", receivedAt: "2026-10-02T08:13:43+00:00", link: nil, attachments: attachments,
            menu: menu, menuError: nil)
    }

    private let pdf = CanteenAttachment(
        id: "a1", filename: "week.pdf", contentType: "application/pdf", size: 10, language: nil)

    // MARK: Wire

    func testCapturedPayloadDecodes() throws {
        let response = try JSONDecoder().decode(CanteenEntriesResponse.self, from: Data(captured.utf8))

        XCTAssertEqual(response.entries.count, 2)
        let bare = response.entries[0]
        XCTAssertNil(bare.link)
        XCTAssertNil(bare.menu)
        XCTAssertTrue(bare.attachments.isEmpty)

        let full = response.entries[1]
        XCTAssertEqual(full.link, "https://forms.cloud.microsoft/Pages/ResponsePage.aspx?id=AAA")
        XCTAssertEqual(full.attachments.map(\.language), ["de", "en"])
        let day = try XCTUnwrap(full.menu?.days.first)
        XCTAssertEqual(day.date, "2026-09-07")
        let meal = try XCTUnwrap(day.meals.first)
        XCTAssertEqual(meal.kind, .vegan)
        XCTAssertEqual(meal.nameEn, "Lentil Curry")
        XCTAssertNil(meal.milk)
        XCTAssertNil(meal.egg)
    }

    func testAnUnknownMealKindIsKeptRatherThanSwallowed() throws {
        let kind = try JSONDecoder().decode(CanteenMealKind.self, from: Data("\"pescatarian\"".utf8))
        XCTAssertEqual(kind, .unrecognized("pescatarian"))
    }

    // MARK: Display

    func testVegetarianFlagsAreMilkBeforeEggAndOnlyWhenPresent() {
        XCTAssertEqual(
            CanteenDisplay.flags(meal(kind: .vegetarian, milk: true, egg: true)).map(\.code), ["G", "C"])
        XCTAssertEqual(
            CanteenDisplay.flags(meal(kind: .vegetarian, milk: false, egg: true)).map(\.code), ["C"])
        XCTAssertTrue(CanteenDisplay.flags(meal(kind: .vegetarian, milk: false, egg: false)).isEmpty)
    }

    func testAVeganMealNeverShowsFlagsWhateverItsCodesSay() {
        XCTAssertTrue(CanteenDisplay.flags(meal(kind: .vegan, milk: true, egg: true)).isEmpty)
    }

    func testMenuStateTellsParsedFromUnreadableFromNoPdfs() {
        XCTAssertEqual(CanteenDisplay.menuState(entry(attachments: [pdf], menu: CanteenMenu(days: []))), .parsed)
        XCTAssertEqual(CanteenDisplay.menuState(entry(attachments: [pdf])), .unparsed)
        XCTAssertEqual(CanteenDisplay.menuState(entry()), .noPdfs)
    }

    func testAttachmentLabelNamesTheLanguageElseTheFile() {
        let de = CanteenAttachment(id: "1", filename: "x.pdf", contentType: "application/pdf", size: 1, language: "de")
        let en = CanteenAttachment(id: "2", filename: "x.pdf", contentType: "application/pdf", size: 1, language: "en")
        XCTAssertEqual(CanteenDisplay.attachmentLabel(de), "Deutsch")
        XCTAssertEqual(CanteenDisplay.attachmentLabel(en), "English")
        XCTAssertEqual(CanteenDisplay.attachmentLabel(pdf), "week.pdf")
    }

    func testMenuSpanIsFirstToLastDatedDayInAnyOrder() {
        let days = ["2026-09-09", nil, "2026-09-07", "2026-09-11"].map {
            CanteenDay(date: $0, labelDe: nil, labelEn: nil, meals: [])
        }
        let span = CanteenDisplay.menuSpan(entry(menu: CanteenMenu(days: days)))
        XCTAssertEqual(span?.from, "2026-09-07")
        XCTAssertEqual(span?.to, "2026-09-11")
        XCTAssertNil(CanteenDisplay.menuSpan(entry()))
    }

    func testDayTitlePrefersGermanThenEnglishThenDate() {
        let day = CanteenDay(date: "2026-09-07", labelDe: "Montag", labelEn: "Monday", meals: [])
        XCTAssertEqual(CanteenDisplay.dayTitle(day), "Montag")
        XCTAssertEqual(
            CanteenDisplay.dayTitle(CanteenDay(date: "2026-09-07", labelDe: nil, labelEn: "Monday", meals: [])),
            "Monday")
        XCTAssertEqual(
            CanteenDisplay.dayTitle(CanteenDay(date: "2026-09-07", labelDe: nil, labelEn: nil, meals: [])),
            "2026-09-07")
    }

}

/// The store's tests are all `async`: Linux's XCTest cannot discover a synchronous method on a
/// main-actor-isolated class, so the synchronous ones live in `CanteenTests` above.
@MainActor
final class CanteenStoreTests: XCTestCase {
    private let pdf = CanteenAttachment(
        id: "a1", filename: "week.pdf", contentType: "application/pdf", size: 10, language: nil)

    func testLoadKeepsTheServersOrder() async throws {
        let api = FakeCanteenApi()
        let entries = ["new", "old"].map {
            CanteenEntry(
                id: $0, receivedAt: "2026-10-02T08:13:43+00:00", link: nil, attachments: [], menu: nil,
                menuError: nil)
        }
        api.result = .success(entries)
        let store = CanteenStore(api: api)

        await store.load()

        XCTAssertEqual(store.entries.map(\.id), ["new", "old"])
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isLoading)
    }

    func testLoadFailureSurfacesAsAMessage() async {
        let api = FakeCanteenApi()
        api.result = .failure(.detail("could not reach the server", statusCode: 500))
        let store = CanteenStore(api: api)

        await store.load()

        XCTAssertEqual(store.errorMessage, "could not reach the server")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAFailedPdfFetchReturnsNilAndSetsTheMessage() async {
        let api = FakeCanteenApi()
        api.attachmentResult = .failure(.detail("gone", statusCode: 404))
        let store = CanteenStore(api: api)

        let data = await store.loadAttachment(entryId: "e1", attachment: pdf)

        XCTAssertNil(data)
        XCTAssertEqual(store.errorMessage, "gone")
        XCTAssertEqual(api.attachmentCalls, ["e1/a1"])
    }
}

private final class FakeCanteenApi: CanteenApiClient, @unchecked Sendable {
    var result: Result<[CanteenEntry], PaiError> = .success([])
    var attachmentResult: Result<Data, PaiError> = .success(Data())
    var attachmentCalls: [String] = []

    func listCanteenEntries() async throws -> [CanteenEntry] {
        try result.get()
    }

    func getCanteenAttachment(entryId: String, attachmentId: String) async throws -> Data {
        attachmentCalls.append("\(entryId)/\(attachmentId)")
        return try attachmentResult.get()
    }
}
