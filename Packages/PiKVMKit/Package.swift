// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PiKVMKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PiKVMKit", targets: ["PiKVMKit"]),
    ],
    targets: [
        .target(
            name: "PiKVMKit",
            // Sent to the PiKVM to read and change its configuration.
            resources: [.copy("Resources/pikvm_config_helper.py")]
        ),
        .testTarget(name: "PiKVMKitTests", dependencies: ["PiKVMKit"]),
    ]
)
