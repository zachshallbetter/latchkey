// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Latchkey",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LatchkeyCore", targets: ["LatchkeyCore"]),
        .executable(name: "latchkey", targets: ["latchkey"]),
        .executable(name: "latchkey-broker", targets: ["latchkey-broker"]),
    ],
    targets: [
        .target(name: "LatchkeyCore"),
        .executableTarget(name: "latchkey", dependencies: ["LatchkeyCore"]),
        .executableTarget(name: "latchkey-broker", dependencies: ["LatchkeyCore"]),
        .testTarget(name: "LatchkeyCoreTests", dependencies: ["LatchkeyCore"]),
    ]
)
