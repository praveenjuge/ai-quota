// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Devbar",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "Devbar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Devbar",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
