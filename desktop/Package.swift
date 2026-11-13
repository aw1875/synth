// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SynthDesktop",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SynthProtocol", targets: ["SynthProtocol"]),
        .library(name: "SynthClient", targets: ["SynthClient"])
    ],
    targets: [
        .target(name: "SynthProtocol"),
        .target(name: "SynthClient", dependencies: ["SynthProtocol"]),
        .testTarget(name: "SynthProtocolTests", dependencies: ["SynthProtocol"]),
        .testTarget(
            name: "SynthClientTests",
            dependencies: ["SynthClient", "SynthProtocol"],
            resources: [.copy("Fixtures")]
        )
    ]
)
