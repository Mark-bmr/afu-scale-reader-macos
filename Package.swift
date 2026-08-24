// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AFUBodyScale",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AFUCore", targets: ["AFUCore"]),
        .executable(name: "AFUReader", targets: ["AFUReader"])
    ],
    targets: [
        .target(name: "AFUCore"),
        .executableTarget(
            name: "AFUReader",
            dependencies: ["AFUCore"],
            linkerSettings: [
                .linkedFramework("CoreBluetooth")
            ]
        ),
        .testTarget(name: "AFUCoreTests", dependencies: ["AFUCore"])
    ]
)
