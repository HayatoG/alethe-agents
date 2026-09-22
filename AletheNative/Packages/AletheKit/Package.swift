// swift-tools-version: 6.2
import PackageDescription

// Domain modules of the native app. Targets are added as their phase tasks begin
// (see docs/MAC_NATIVE_V2_PLAN.md, ADR-7).
let package = Package(
    name: "AletheKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AletheFoundation", targets: ["AletheFoundation"]),
    ],
    targets: [
        .target(name: "AletheFoundation"),
        .testTarget(name: "AletheFoundationTests", dependencies: ["AletheFoundation"]),
    ]
)
