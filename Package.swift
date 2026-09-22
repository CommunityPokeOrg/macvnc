// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "rfbvnc",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "rfbvnc", path: "Sources/rfbvnc")
    ]
)
