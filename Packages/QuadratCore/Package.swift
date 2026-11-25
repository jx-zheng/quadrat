// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "QuadratCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "QuadratCore", targets: ["QuadratCore"])
    ],
    targets: [
        .target(
            name: "QuadratCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuadratCoreTests",
            dependencies: ["QuadratCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
