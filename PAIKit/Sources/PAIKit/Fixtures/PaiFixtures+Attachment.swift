import Foundation

extension PaiFixtures {
    /// The VM path the transcript fixture's own `pai-file:` marker (`PaiFixtures+Transcript.swift`)
    /// names — shared rather than duplicated, so the marker's text and the fixture route answering
    /// a fetch for it can never drift apart.
    public static let attachmentPath = "/home/frederik/.tmp/reconcile-diff.png"

    /// A real, decodable 240×160 PNG — a banded pattern, not a flat fill, so a screenshot of the
    /// full-screen viewer shows something rather than a single solid colour. Base64 rather than a
    /// bundled resource, for the same one-lookup-path reason every other fixture here is a string
    /// literal (`PaiFixtures.swift`'s own doc comment).
    ///
    /// `GET /api/session/{id}/attachment` had no fixture route at all before this existed — every
    /// attachment chip and note image embed in fixture mode failed with a 404, silently, since
    /// nothing screenshots the resulting error state. This is what the full-screen image viewer's
    /// own fixture screenshot (`-PaiFixtureOpenImage`) actually decodes.
    public static var attachmentImage: Data {
        Data(base64Encoded: attachmentImageBase64) ?? Data()
    }

    private static let attachmentImageBase64 = """
        iVBORw0KGgoAAAANSUhEUgAAAPAAAACgCAIAAAC9uXYyAAACzUlEQVR42u3dMW1AQQxEwcV1WIzokLk+AB9LEKSJlGY1kvuR1gBe\
        ztw/377vz8fl/ocbK3Ob3FiZ2+TGytwmN1bmNrmxMrfJjZW5TW6szG1yY2Vukxsrc5vcWJnb5MbK3CY3VuY2ubEyt8mNlblNbqzM\
        bXJjZW6TGytzm9xYmdvkxsrcJjdW5ja5sTK3yY2VuU1urMxtcmNlbpMbK3Ob3FiZ2+TGytwmN1bmNrmxMrfJjZW5TW6szG1yY2Vu\
        kxsrc5vcWJnb5MbK3CY3VuY2ubEyt8mNlblNbqzMbXJjZe7RKbQyd3UKfZerU8jl6hRyR6fQytynU2hlrk6h73J1CrlcnULu6BRa\
        mft0Cq3MHZ1CLlenkMvVKeRenUIrcz+dQitzr04hl6tTyOXqFHJXp9DK3KNTaGWuTiGXq1PI5eoUclen0Mrco1Pou1ydQi5Xp5D7\
        dAqtzB2dQitzn06h73JHp5DL1Snkrk6hlblHp9DK3NUp5HJ1CrlcnULu6BRamatTaGXu6hRyuTqFXK5OIXd0Cq3MfTqFVubqFHK5\
        OoVcrk4hd3QKrcx9OoVW5uoUcrk6hVyuTiH36RRamTs6hb7L1SnkcnUKuVen0MrcT6fQytyrU+i7XJ1CLlenkLs6hVbmHp1CK3NX\
        p5DL1SnkcnUKuU+n0Mrc0Sm0MvfpFHK5OoVcrk4h99MptDL36hRamatTyOXqFHK5OoXcq1NoZe6nU+i7XJ1CLlenkLs6hVbmHp1C\
        K3NXp9B3uTqFXK5OIXd0Cq3MfTqFVuaOTiGXq1PI5eoUcq9OoZW5n06hlblXp5DL1SnkcnUKuatTaGXu0Sm0MlenkMvVKeRydQq5\
        q1NoZe7RKbQyV6eQy9Up5HJ1CrmrU2hl7tEp9F2uTiGXq1PIfTqFVuaOTqGVuU+n0He5OoVcrk4h99MptDL36hRamfvpFHK5OoVc\
        7u/3A4Ljl8TtaBLxAAAAAElFTkSuQmCC
        """
}
