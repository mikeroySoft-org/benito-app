// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BenitoKit",
    platforms: [
        .iOS(.v17),
        .watchOS(.v10),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BenitoKit", targets: ["BenitoKit"]),
    ],
    dependencies: [
        // Local-first store (SPEC). Resolves on a Mac with network; Linux CI may skip resolve.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "BenitoKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/BenitoKit"
        ),
        .testTarget(
            name: "BenitoKitTests",
            dependencies: ["BenitoKit"],
            path: "Tests/BenitoKitTests"
        ),
    ]
)
