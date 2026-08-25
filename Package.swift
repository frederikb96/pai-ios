// swift-tools-version: 6.2
import PackageDescription

// Nearly all of the app lives here rather than in the Xcode project, for two reasons.
//
// It is authorable without a Mac: a Package.swift is a plain, reviewable file, whereas a
// hand-written .xcodeproj is an opaque plist that cannot be validated without Xcode. Writing one
// blind and hoping is the clever-over-boring choice; this is the boring one.
//
// It also keeps the app target thin enough that creating it on the first Mac session is a
// two-minute job rather than a risk, and it means logic can be tested without an app host.

let package = Package(
    name: "PAIKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "PAIKit", targets: ["PAIKit"])
    ],
    dependencies: [
        // Apple's cmark-gfm wrapper, so GFM tables, task lists and strikethrough are
        // spec-correct rather than approximated by hand. Foundation's own
        // `AttributedString(markdown:)` cannot express a table at all, which rules it out.
        //
        // Pinned to the next minor rather than the next major: this is pre-1.0, where a minor
        // bump is allowed to break API, and `from:` would accept every one of them.
        .package(url: "https://github.com/apple/swift-markdown.git", .upToNextMinor(from: "0.8.0"))
    ],
    targets: [
        .target(
            name: "PAIKit",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "PAIKit/Sources/PAIKit"
        ),
        .testTarget(
            name: "PAIKitTests",
            dependencies: ["PAIKit"],
            path: "PAIKit/Tests/PAIKitTests"
        )
    ]
)
