// swift-tools-version:6.0

// Signal's RingRTC for Signal calls on iOS. SignalRingRTC's own package
// leaves the Rust library (LibRingRTCFfi) to the app, so this adds Signal's
// prebuilt one for the same release. Bump both versions together.
import PackageDescription

let package = Package(
    name: "SwitchboardRingRTC",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "SwitchboardRingRTC", targets: ["SwitchboardRingRTC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/signalapp/ringrtc", exact: "2.74.0"),
    ],
    targets: [
        .binaryTarget(
            name: "LibRingRTCFfi",
            url: "https://build-artifacts.signal.org/libraries/ringrtc-ios-build-v2.74.0.xcframework.zip",
            checksum: "789d702a2e0ce00da851c118e40d80bc73e4b3c7b43c6846be2210c6f6b81104"
        ),
        .target(
            name: "SwitchboardRingRTC",
            dependencies: [
                .product(name: "SignalRingRTC", package: "ringrtc"),
                "LibRingRTCFfi",
            ]
        ),
    ]
)
