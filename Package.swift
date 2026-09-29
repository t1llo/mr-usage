// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MrUsage",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ClaudeUsageBar", targets: ["MrUsage"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "MrUsage",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ],
    swiftLanguageModes: [.v5]
)
