// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FolderBackup",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FolderBackup", targets: ["FolderBackup"])],
    targets: [
        .target(name: "BackupCore", resources: [.process("Resources")]),
        .executableTarget(name: "FolderBackup", dependencies: ["BackupCore"]),
        .executableTarget(name: "BackupCoreChecks", dependencies: ["BackupCore"], path: "Tests/BackupCoreTests", exclude: ["BackupEngineTests.swift.reference"])
    ],
    swiftLanguageModes: [.v5]
)
