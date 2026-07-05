// swift-tools-version: 6.2
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let useLocalDeps = ProcessInfo.processInfo.environment["AISTACK_USE_LOCAL_DEPS"] == "1"
    || ProcessInfo.processInfo.environment["MEMBRANE_USE_LOCAL_DEPS"] == "1"

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
]

if useLocalDeps {
    dependencies += [
        .package(path: packageRoot.appendingPathComponent("../ContextCore").path),
    ]
} else {
    dependencies += [
        .package(url: "https://github.com/christopherkarani/ContextCore.git", from: "1.0.0"),
    ]
}

let package = Package(
    name: "Membrane",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "MembraneCore", targets: ["MembraneCore"]),
        .library(name: "Membrane", targets: ["Membrane"]),
        .library(name: "MembraneContextCore", targets: ["MembraneContextCore"]),
    ],
    dependencies: dependencies,
    targets: [
        .target(
            name: "MembraneCore",
            dependencies: [
                .product(name: "OrderedCollections", package: "swift-collections"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Membrane",
            dependencies: [
                "MembraneCore",
                "MembraneContextCore",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MembraneContextCore",
            dependencies: [
                "MembraneCore",
                .product(name: "ContextCore", package: "ContextCore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MembraneCoreTests",
            dependencies: ["MembraneCore"]
        ),
        .testTarget(
            name: "MembraneTests",
            dependencies: ["Membrane"]
        ),
    ]
)
