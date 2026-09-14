// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacSelectedTranslator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SelectedTextTranslatorApp",
            targets: ["SelectedTextTranslatorApp"]
        ),
        .executable(
            name: "WorkspaceChromeHost",
            targets: ["WorkspaceChromeHost"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SelectedTextTranslatorApp",
            dependencies: ["WorkspaceSkyLightBridge"],
            resources: [.copy("Resources/Flowchart")]
        ),
        .target(name: "WorkspaceSkyLightBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "WorkspaceChromeHost"),
        .testTarget(
            name: "SelectedTextTranslatorAppTests",
            dependencies: ["SelectedTextTranslatorApp"],
            path: "tests/SelectedTextTranslatorAppTests"
        )
    ]
)
