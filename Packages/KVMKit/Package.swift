// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KVMKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KVMKit", targets: ["KVMKit"]),
    ],
    targets: [
        .target(
            name: "KVMKit",
            // Sent to the PiKVM to read and change its configuration.
            resources: [.copy("Resources/pikvm_config_helper.py")]
        ),
        .testTarget(name: "KVMKitTests", dependencies: ["KVMKit"]),
    ]
)
