// swift-tools-version: 6.2
import PackageDescription

// Nearly all of the app lives here rather than in the Xcode project.
//
// A Package.swift is plainly reviewable where a project file is not, it builds and tests on any
// macOS runner without an Apple credential, and it keeps the app target thin — the app holds
// views and wiring, and everything worth testing without an app host lives here.

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
            ]
        ),
        .testTarget(
            name: "PAIKitTests",
            dependencies: [
                "PAIKit",
                // Named explicitly, not left transitive: a markdown test calls the internal
                // parse seam, whose signature is typed in this module.
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
