// swift-tools-version: 5.9
import Foundation
import PackageDescription

func existingXCFrameworkPath() -> String {
    let fm = FileManager.default
    let candidates = [
        "../../zig-out/lib/ghostty-vt.xcframework",
        "../../zig-out/xcframeworks/ghostty-vt.xcframework",
        "../../zig-out/ghostty-vt.xcframework",
    ]

    for rel in candidates {
        let plist = "\(rel)/Info.plist"
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: rel, isDirectory: &isDir),
            isDir.boolValue,
            fm.fileExists(atPath: plist)
        {
            return rel  // important to return relative path
        }
    }

    fatalError(
        """
        GhosttyVt XCFramework not found.
        Build it first (must produce a valid *.xcframework with Info.plist).
        Tried:
        \(candidates.joined(separator: "\n"))
        """)
}

let package = Package(
    name: "swift-vt-xcframework",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "swift-vt-xcframework",
            dependencies: ["GhosttyVt"],
            path: "Sources",
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .binaryTarget(
            name: "GhosttyVt",
            path: existingXCFrameworkPath()
        ),
    ]
)
