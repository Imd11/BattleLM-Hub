// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BattleLMShared",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "BattleLMShared", targets: ["BattleLMShared"]),
    ],
    targets: [
        .target(name: "BattleLMShared"),
    ]
)
