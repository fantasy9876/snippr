// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Snippr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Snippr",
            path: "Sources/Snippr",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
