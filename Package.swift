// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "VertesiaClient",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "VertesiaClient", targets: ["VertesiaClient"])],
    targets: [
        .target(name: "VertesiaClient"),
        .testTarget(name: "VertesiaClientTests", dependencies: ["VertesiaClient"])
    ]
)
