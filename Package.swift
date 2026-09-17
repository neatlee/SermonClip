// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SermonCut",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "SermonCut", targets: ["SermonCut"])],
    targets: [
        .executableTarget(
            name: "SermonCut",
            path: "Sources/SermonCut",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "SermonCutTests",
            dependencies: ["SermonCut"],
            path: "Tests/SermonCutTests"
        )
    ]
)
