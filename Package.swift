// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacGleam",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "GleamApp",
            targets: ["GleamApp"]
        ),
        .executable(
            name: "WorkspaceChromeHost",
            targets: ["WorkspaceChromeHost"]
        )
    ],
    targets: [
        .executableTarget(
            name: "GleamApp",
            dependencies: ["WorkspaceSkyLightBridge"],
            resources: [.copy("Resources/Flowchart")]
        ),
        .target(name: "WorkspaceSkyLightBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "WorkspaceChromeHost"),
        .testTarget(
            name: "GleamAppTests",
            dependencies: ["GleamApp"],
            path: "tests/GleamAppTests"
        )
    ]
)
