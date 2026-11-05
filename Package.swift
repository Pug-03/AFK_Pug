// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AFKPug",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AFKPug",
            path: "Sources/AFKPug",
            linkerSettings: [.linkedFramework("IOKit")]
        )
    ]
)
