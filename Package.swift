// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinDACore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WinDACore", targets: ["WinDACore"]),
        .executable(name: "winda-recipe", targets: ["winda-recipe"]),
        .executable(name: "winda-spike", targets: ["winda-spike"]),
        .executable(name: "winda-engine", targets: ["winda-engine"]),
        .executable(name: "winda-bottle", targets: ["winda-bottle"]),
        .executable(name: "winda-shortcut", targets: ["winda-shortcut"]),
        .executable(name: "WinDA", targets: ["WinDA"]),
        .executable(name: "winda-gptk", targets: ["winda-gptk"]),
    ],
    targets: [
        .target(name: "WinDACore", resources: [.copy("Resources/dx11test.exe"), .copy("Resources/helper-wrapper.exe")]),
        .executableTarget(name: "winda-recipe", dependencies: ["WinDACore"]),
        .executableTarget(name: "winda-spike", dependencies: ["WinDACore"]),
        .executableTarget(name: "winda-engine", dependencies: ["WinDACore"]),
        .executableTarget(name: "winda-bottle", dependencies: ["WinDACore"]),
        .executableTarget(name: "winda-shortcut", dependencies: ["WinDACore"]),
        .executableTarget(name: "WinDA", dependencies: ["WinDACore"]),
        .executableTarget(name: "winda-gptk", dependencies: ["WinDACore"]),
        .testTarget(name: "WinDACoreTests", dependencies: ["WinDACore"]),
    ]
)
