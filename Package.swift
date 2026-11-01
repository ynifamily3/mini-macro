// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMacro",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacMacro", targets: ["MacMacro"])],
    targets: [
        .target(name: "MacroCore"),
        .executableTarget(name: "MacMacro", dependencies: ["MacroCore"]),
        .testTarget(name: "MacroCoreTests", dependencies: ["MacroCore"]),
        .testTarget(name: "MacMacroTests", dependencies: ["MacMacro", "MacroCore"])
    ],
    swiftLanguageModes: [.v5]
)
