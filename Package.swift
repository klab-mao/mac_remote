// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mac_remote",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MacRemoteCore"),
        .executableTarget(
            name: "mac_remote_host",
            dependencies: ["MacRemoteCore"]
        ),
        .executableTarget(
            name: "mac_remote_client",
            dependencies: ["MacRemoteCore"]
        )
    ]
)