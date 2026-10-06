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
        .executable(name: "signalhive-packbuilder", targets: ["signalhive-packbuilder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
        // The native RTL-SDR driver (also published on its own: github.com/noktirnal42/SwiftRTLSDR).
        .package(path: "../SwiftRTLSDR"),
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
                .product(name: "RTLSDRKit", package: "SwiftRTLSDR", condition: .when(platforms: [.macOS])),
                .product(name: "RTLSDRScan", package: "SwiftRTLSDR", condition: .when(platforms: [.macOS])),
                .product(name: "RTLSDRDecoders", package: "SwiftRTLSDR", condition: .when(platforms: [.macOS])),
            ],
            path: "Sources/SignalHiveCore",
            resources: [
                .process("DSP/Models"),
                .process("Satellite/Catalog/Resources"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "signalhive-packbuilder",
            dependencies: ["SignalHiveCore"],
            path: "Sources/signalhive-packbuilder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SignalHiveCoreTests",
            dependencies: ["SignalHiveCore"],
            path: "Tests/Core",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
