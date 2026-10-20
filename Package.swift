// swift-tools-version:5.7
import PackageDescription

// Le toolchain Swift recenti non includono più le librerie di retro-compatibilità
// del runtime (libswiftCompatibility56 & co.) per x86_64: senza questo flag il link
// per l'iMac Intel fallisce. Su macOS 12.3+ il runtime di sistema basta.
let noBackDeployLibs: [SwiftSetting] = [
    .unsafeFlags(["-runtime-compatibility-version", "none"]),
]

let package = Package(
    name: "Lazarus5K",
    // L'iMac late 2015 arriva al massimo a Monterey: serve almeno la 12.3 (ScreenCaptureKit).
    platforms: [.macOS("12.3")],
    products: [
        .executable(name: "Lazarus5K", targets: ["Lazarus5K"]),
        .executable(name: "RelayHost", targets: ["RelayHost"]),
        .executable(name: "RelayViewer", targets: ["RelayViewer"]),
    ],
    targets: [
        .target(name: "CGVirtualDisplayPrivate",
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "Shared",
                swiftSettings: noBackDeployLibs),
        .target(name: "HostCore",
                dependencies: ["CGVirtualDisplayPrivate", "Shared"],
                swiftSettings: noBackDeployLibs),
        .target(name: "ViewerCore",
                dependencies: ["Shared"],
                swiftSettings: noBackDeployLibs),
        .executableTarget(name: "Lazarus5K",
                          dependencies: ["HostCore", "ViewerCore"],
                          swiftSettings: noBackDeployLibs),
        .executableTarget(name: "RelayHost",
                          dependencies: ["HostCore"],
                          swiftSettings: noBackDeployLibs),
        .executableTarget(name: "RelayViewer",
                          dependencies: ["ViewerCore"],
                          swiftSettings: noBackDeployLibs),
    ]
)
