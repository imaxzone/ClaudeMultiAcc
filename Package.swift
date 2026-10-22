// swift-tools-version: 6.2
import PackageDescription
let package = Package(
  name: "ClaudeMultiAcc",
  defaultLocalization: "en",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "ClaudeMultiAcc", targets: ["ClaudeMultiAcc"]),
    .executable(name: "cmacc", targets: ["cmacc"]),
    .executable(name: "CloneLauncher", targets: ["CloneLauncher"]),
  ],
  targets: [
    .target(name: "Support", resources: [.process("Resources")]),
    .target(name: "IconRenderer", dependencies: ["Support"]),
    .target(name: "InstanceBuilder", dependencies: ["Support", "IconRenderer"], resources: [.process("Resources")]),
    .target(name: "LinkRouter", dependencies: ["Support"]),
    .target(
      name: "UI", dependencies: ["Support", "IconRenderer", "InstanceBuilder", "LinkRouter"],
      resources: [.process("Resources")]),
    .executableTarget(name: "ClaudeMultiAcc", dependencies: ["UI"]),
    .executableTarget(name: "cmacc", dependencies: ["Support", "IconRenderer", "InstanceBuilder", "LinkRouter", "UI"]),
    .executableTarget(name: "CloneLauncher"),
    .testTarget(name: "SupportTests", dependencies: ["Support"], resources: [.copy("Fixtures")]),
    .testTarget(name: "IconRendererTests", dependencies: ["IconRenderer", "Support"]),
    .testTarget(name: "InstanceBuilderTests", dependencies: ["InstanceBuilder"], resources: [.copy("Fixtures")]),
    .testTarget(name: "LinkRouterTests", dependencies: ["LinkRouter"], resources: [.copy("Fixtures")]),
    .testTarget(name: "UITests", dependencies: ["UI", "Support", "IconRenderer", "InstanceBuilder"], resources: [.copy("Fixtures")]),
    .testTarget(name: "CloneLauncherTests", dependencies: ["CloneLauncher"]),
    .testTarget(name: "cmaccTests", dependencies: ["cmacc", "Support", "InstanceBuilder"]),
  ]
)
