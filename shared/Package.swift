// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WadosMAAShared",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "WadosMAAShared", targets: ["WadosMAAShared"])
    ],
    targets: [
        .target(name: "WadosMAAShared"),
        .testTarget(name: "WadosMAASharedTests", dependencies: ["WadosMAAShared"]),
    ]
)
