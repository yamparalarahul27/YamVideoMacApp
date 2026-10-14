// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YamparalaVideo",
    platforms: [.macOS(.v15)],
    targets: [
        // Pipeline logic only: EditDoc, probing, export planning and execution.
        // Never imports SwiftUI/AppKit — a later `yv` CLI depends on this alone.
        .target(
            name: "YVCore",
            path: "Sources/YVCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "YamparalaVideo",
            dependencies: ["YVCore"],
            path: "Sources/YamparalaVideo",
            // Swift 5 mode: the capture code from Pen-Fight-Stream was written
            // for it, and fighting strict concurrency isn't Phase 0 work.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "YVCoreTests",
            dependencies: ["YVCore"],
            path: "Tests/YVCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
