// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "google-play-books-downloader",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ScreenshoterCore"),
        .executableTarget(name: "google-play-books-downloader", dependencies: ["ScreenshoterCore"]),
        .testTarget(name: "ScreenshoterCoreTests", dependencies: ["ScreenshoterCore"]),
    ]
)
