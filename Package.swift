// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Knock",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "KnockCore"),
        .executableTarget(name: "knockd", dependencies: ["KnockCore"]),
        .executableTarget(name: "KnockAgent", dependencies: ["KnockCore"]),
        .testTarget(name: "KnockCoreTests", dependencies: ["KnockCore"]),
    ]
)
