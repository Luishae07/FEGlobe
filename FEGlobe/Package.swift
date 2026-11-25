// swift-tools-version:5.9
// SPDX-License-Identifier: AGPL-3.0-or-later
import PackageDescription

let package = Package(
    name: "FEGlobe",
    platforms: [.iOS(.v17)],
    products: [.library(name: "FEGlobe", targets: ["FEGlobe"])],
    targets: [
        .target(name: "FEGlobe", resources: [.process("Resources")]),
        .testTarget(name: "FEGlobeTests", dependencies: ["FEGlobe"])
    ]
)
