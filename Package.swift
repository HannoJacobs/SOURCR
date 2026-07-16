// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SOURCR",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SOURCR",
            path: "Sources/SOURCR",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "SOURCRTests",
            dependencies: ["SOURCR"],
            path: "Tests/SOURCRTests"
        ),
    ]
)
