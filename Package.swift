// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeatGuard",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "HeatGuard", targets: ["HeatGuard"])
    ],
    targets: [
        .target(
            name: "HeatGuardNative",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "HeatGuard",
            dependencies: ["HeatGuardNative"]
        )
    ]
)
