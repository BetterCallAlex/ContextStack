// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ContextStack",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ContextStack",
            path: "Sources/ContextStack",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
