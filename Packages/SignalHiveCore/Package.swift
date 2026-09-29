// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SignalHiveCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "SignalHiveCore", targets: ["SignalHiveCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "CMbelib",
            path: "Sources/CMbelib",
            publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-Wno-everything"])]
        ),
        .target(
            name: "SignalHiveCore",
            dependencies: [
                "CMbelib",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/SignalHiveCore",
            resources: [
                .process("DSP/Models"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SignalHiveCoreTests",
            dependencies: ["SignalHiveCore"],
            path: "Tests/Core",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
