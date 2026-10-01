// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIQuota",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "AIQuota",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AIQuota",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
