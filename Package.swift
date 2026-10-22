// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Filmstrip",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Filmstrip", targets: ["FilmstripApp"]),
        .library(name: "FilmstripCore", targets: ["FilmstripCore"]),
    ],
    targets: [
        // Pure layout logic. No AppKit, no Accessibility: fully unit-testable.
        .target(name: "FilmstripCore"),
        // Everything that talks to macOS: Accessibility, event taps, displays, Spaces.
        .target(name: "FilmstripPlatform", dependencies: ["FilmstripCore"]),
        // The menu bar app: controller, minimap, onboarding.
        .executableTarget(name: "FilmstripApp", dependencies: ["FilmstripCore", "FilmstripPlatform"]),
        .testTarget(name: "FilmstripCoreTests", dependencies: ["FilmstripCore"]),
    ]
)
