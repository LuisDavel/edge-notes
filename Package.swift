// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EdgeNotes",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "EdgeNotesCore"),
        .executableTarget(name: "EdgeNotesApp", dependencies: ["EdgeNotesCore"]),
        .testTarget(name: "EdgeNotesCoreTests", dependencies: ["EdgeNotesCore"]),
    ]
)
