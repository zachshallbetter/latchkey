// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Latchkey",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LatchkeyCore", targets: ["LatchkeyCore"]),
        // GitHub's sealed box, kept out of LatchkeyCore so the App Store build carries no encryption of its own.
        .library(name: "LatchkeySeal", targets: ["LatchkeySeal"]),
        .executable(name: "latchkey", targets: ["latchkey"]),
        .executable(name: "latchkey-broker", targets: ["latchkey-broker"]),
    ],
    targets: [
        .target(name: "LatchkeyCore"),
        .target(name: "LatchkeySeal"),
        .executableTarget(name: "latchkey", dependencies: ["LatchkeyCore"]),
        .executableTarget(name: "latchkey-broker", dependencies: ["LatchkeyCore"]),
        .testTarget(name: "LatchkeyCoreTests", dependencies: ["LatchkeyCore", "LatchkeySeal"]),
        .testTarget(name: "LatchkeySealTests", dependencies: ["LatchkeySeal"]),
        .testTarget(name: "LatchkeyRunTests", dependencies: ["latchkey"]),
    ]
)
