// swift-tools-version:5.7
import PackageDescription

// Le toolchain Swift recenti non includono più le librerie di retro-compatibilità
// del runtime (libswiftCompatibility56 & co.) per x86_64: senza questo flag il link
// del Viewer per l'iMac Intel fallisce. Su macOS 12.3+ il runtime di sistema basta.
let noBackDeployLibs: [SwiftSetting] = [
    .unsafeFlags(["-runtime-compatibility-version", "none"]),
]

let package = Package(
    name: "RelayLite",
    // L'iMac late 2015 arriva al massimo a Monterey: serve almeno la 12.3 (ScreenCaptureKit).
    platforms: [.macOS("12.3")],
    products: [
        .executable(name: "RelayHost", targets: ["RelayHost"]),
        .executable(name: "RelayViewer", targets: ["RelayViewer"]),
    ],
    targets: [
        .target(name: "CGVirtualDisplayPrivate",
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "Shared",
                swiftSettings: noBackDeployLibs),
        .executableTarget(name: "RelayHost",
                          dependencies: ["CGVirtualDisplayPrivate", "Shared"]),
        .executableTarget(name: "RelayViewer",
                          dependencies: ["Shared"],
                          swiftSettings: noBackDeployLibs),
    ]
)
