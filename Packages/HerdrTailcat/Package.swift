// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerdrTailcat",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HerdrTailcat", targets: ["HerdrTailcat"])
    ],
    targets: [
        // The gomobile-built tailcat (WireGuard/DERP) client. macOS only.
        .binaryTarget(
            name: "Tailcat",
            path: "Artifacts/Tailcat.xcframework"
        ),
        .target(
            name: "HerdrTailcat",
            dependencies: ["Tailcat"]
        ),
    ]
)
