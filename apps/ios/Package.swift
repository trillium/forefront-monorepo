// swift-tools-version: 5.9
import PackageDescription

// Forefront is shipped as an iOS App built in Xcode.
// This Package.swift exposes the non-UI layers (Models, Storage, Networking)
// as library targets so they can be unit-tested with `swift test` from the
// command line. The UI layers (UI/CardStack, UI/Onboarding, UI/WebView, App)
// live in the same source tree but are consumed by an Xcode iOS App target —
// they intentionally do NOT compile via `swift build` because SwiftUI on iOS
// needs the iOS SDK, which Xcode (not raw swiftpm) brings in.
//
// See README.md → "Open in Xcode" for the iOS App target setup steps.
let package = Package(
    name: "Forefront",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)  // macOS listed only so `swift test` can run model + cache unit tests on a Mac.
    ],
    products: [
        .library(name: "ForefrontModels", targets: ["ForefrontModels"]),
        .library(name: "ForefrontStorage", targets: ["ForefrontStorage"]),
        .library(name: "ForefrontNetworking", targets: ["ForefrontNetworking"])
    ],
    targets: [
        .target(
            name: "ForefrontModels",
            path: "Forefront/Models"
        ),
        .target(
            name: "ForefrontStorage",
            dependencies: ["ForefrontModels"],
            path: "Forefront/Storage"
        ),
        .target(
            name: "ForefrontNetworking",
            dependencies: ["ForefrontModels", "ForefrontStorage"],
            path: "Forefront/Networking"
        ),
        .testTarget(
            name: "ForefrontTests",
            dependencies: ["ForefrontModels", "ForefrontStorage", "ForefrontNetworking"],
            path: "ForefrontTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
