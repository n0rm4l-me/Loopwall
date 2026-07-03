// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Loopwall",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Loopwall",
            path: "Sources/Loopwall",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "LoopwallTests",
            dependencies: [],
            path: "Tests/LoopwallTests"
        ),
    ]
)
