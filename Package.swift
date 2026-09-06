// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TokenBar", targets: ["TokenBar"]),
    ],
    targets: [
        .executableTarget(
            name: "TokenBar",
            path: "Sources/TokenBar",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
