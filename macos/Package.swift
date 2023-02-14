// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to
// build this package.

import PackageDescription

let package = Package(
  name: "Ghostty",
  platforms: [
    // SwiftUI
    .macOS(.v11),
  ],
  products: [
    .executable(
      name: "Ghostty",
      targets: ["Ghostty"]),
  ],
  dependencies: [],
  targets: [
    .executableTarget(
      name: "Ghostty",
      dependencies: ["GhosttyKit"]),
	.binaryTarget(
      name: "GhosttyKit",
      path: "GhosttyKit.xcframework"),
  ]
)
