// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AccioComputerUse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AccioComputerUseKit", targets: ["AccioComputerUseKit"]),
        .executable(name: "AccioComputerUse", targets: ["AccioComputerUse"]),
    ],
    targets: [
        .target(
            name: "AccioComputerUseKit",
            path: "packages/AccioComputerUseKit/Sources/AccioComputerUseKit",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "AccioComputerUse",
            dependencies: ["AccioComputerUseKit"],
            path: "apps/AccioComputerUse/Sources/AccioComputerUse"
        ),
        .testTarget(
            name: "AccioComputerUseKitTests",
            dependencies: ["AccioComputerUseKit"],
            path: "packages/AccioComputerUseKit/Tests/AccioComputerUseKitTests"
        ),
    ]
)
