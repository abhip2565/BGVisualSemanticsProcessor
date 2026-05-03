// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BGVisualSemanticsProcessor",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "BGVisualSemanticsProcessor",
            targets: ["BGVisualSemanticsProcessor"]),
        .library(
            name: "BGVisualSemanticsProcessorVision",
            targets: ["BGVisualSemanticsProcessorVision"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "BGVisualSemanticsProcessor",
            dependencies: [],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]),
        .target(
            name: "BGVisualSemanticsProcessorVision",
            dependencies: ["BGVisualSemanticsProcessor"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]),
        .testTarget(
            name: "BGVisualSemanticsProcessorTests",
            dependencies: ["BGVisualSemanticsProcessor", "BGVisualSemanticsProcessorVision"]),
    ]
)
