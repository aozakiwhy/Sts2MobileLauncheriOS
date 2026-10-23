// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LauncherCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "LauncherCore", targets: ["LauncherCore"])],
    targets: [
        .target(name: "LauncherCore"),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore"])
    ]
)
