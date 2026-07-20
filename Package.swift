// swift-tools-version: 6.0
import Foundation
import PackageDescription

let usesCommandLineTools = !FileManager.default.fileExists(
    atPath: "/Applications/Xcode.app/Contents/Developer")
let testingSwiftSettings: [SwiftSetting] = usesCommandLineTools ? [
    .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
] : []
let testingLinkerSettings: [LinkerSetting] = (usesCommandLineTools ? [
    .unsafeFlags([
        "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        "-Xlinker", "-rpath",
        "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ]),
] : []) + [
    .linkedFramework("Testing"),
]

let package = Package(
    name: "CodexBalance",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "CodexBalanceCore", targets: ["CodexBalanceCore"]),
        .executable(name: "CodexBalance", targets: ["CodexBalance"]),
    ],
    targets: [
        .target(
            name: "CodexBalanceCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .executableTarget(
            name: "CodexBalance",
            dependencies: ["CodexBalanceCore"],
            resources: [
                .process("Resources"),
            ]),
        .executableTarget(
            name: "CodexBalanceTestHarness",
            dependencies: ["CodexBalanceCore"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]),
        .testTarget(
            name: "CodexBalanceCoreTests",
            dependencies: ["CodexBalanceCore"],
            swiftSettings: testingSwiftSettings,
            linkerSettings: testingLinkerSettings),
    ])
