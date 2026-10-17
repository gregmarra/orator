// swift-tools-version: 6.0
import PackageDescription

// Orator — menu-bar dictation utility for macOS 26+ (Apple Silicon).
// Single app, no third-party runtime dependencies (ORA-PLAT-003 / M6).
//
// Layout:
//   OratorKit  — library holding every component (testable)
//   Orator     — the LSUIElement app executable (NSApplication bootstrap)
let package = Package(
    name: "Orator",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "OratorKit"),
        .executableTarget(name: "Orator", dependencies: ["OratorKit"]),
        .testTarget(name: "OratorKitTests", dependencies: ["OratorKit"]),
    ]
)
