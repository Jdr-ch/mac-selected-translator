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
        )
    ],
    targets: [
        .executableTarget(
            name: "SelectedTextTranslatorApp"
        )
    ]
)
