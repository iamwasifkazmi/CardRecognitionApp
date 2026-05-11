// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CardRecognitionApp",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .executable(name: "CardRecognitionApp", targets: ["CardRecognitionApp"]),
    ],
    targets: [
        .executableTarget(
            name: "CardRecognitionApp",
            path: "Sources/CardRecognitionApp"
        ),
        .testTarget(
            name: "CardRecognitionAppTests",
            dependencies: ["CardRecognitionApp"],
            path: "Tests/CardRecognitionAppTests"
        ),
    ]
)
