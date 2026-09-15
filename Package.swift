// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "grounding-contract-kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "GroundingContract", targets: ["GroundingContract"]),
        .library(name: "GroundingContractUI", targets: ["GroundingContractUI"])
    ],
    targets: [
        .target(
            name: "GroundingContract",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "GroundingContractUI",
            dependencies: ["GroundingContract"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GroundingContractTests",
            dependencies: ["GroundingContract"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
