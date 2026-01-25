// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DebugBridge",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DebugBridge", targets: ["DebugBridge"]),
    ],
    targets: [
        .target(name: "DebugBridge"),
    ]
)
