// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FlowFinderNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "FlowFinderNative",
            targets: ["FlowFinderNative"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "FlowFinderNative",
            path: "FlowFinderNative",
            exclude: ["Resources", "Libraries"],
            publicHeadersPath: "include",
            swiftSettings: [
                .unsafeFlags(["-I", "../rust-core/include"]),
                .unsafeFlags(["-I", "include"])
            ],
            linkerSettings: [
                .linkedLibrary("flowfinder_core", .when(platforms: [.macOS])),
                .linkedFramework("QuickLook", .when(platforms: [.macOS])),
                .unsafeFlags(["-L", "../rust-core/target/debug"], .when(platforms: [.macOS]))
            ]
        )
    ]
)
