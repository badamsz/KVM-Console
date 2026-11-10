// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PiKVMKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PiKVMKit", targets: ["PiKVMKit"]),
    ],
    targets: [
        .target(name: "PiKVMKit"),
        .testTarget(name: "PiKVMKitTests", dependencies: ["PiKVMKit"]),
    ]
)
