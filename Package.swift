// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexGateway",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .executable(
            name: "CodexGateway",
            targets: ["CodexGateway"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "CodexGateway",
            path: "CodexGateway",
            exclude: [
                // Packaged via scripts/bundle-cursor-bridge.sh (npm ci + copy into .app)
                "Resources/CursorBridge",
            ],
            resources: [
                .process("Resources/Assets.xcassets"),
                // Apple-standard localization bundles mirrored from L10nTable.
                .process("Resources/en.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
        .testTarget(
            name: "CodexGatewayTests",
            dependencies: ["CodexGateway"]
        )
    ]
)
