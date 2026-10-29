// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AudreyTalk",
  platforms: [.macOS(.v14)],
  dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.0")],
  targets: [
    .executableTarget(
      name: "AudreyTalk",
      dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
      path: "Sources/AudreyTalk",
      swiftSettings: [.swiftLanguageMode(.v5)]
    )
  ]
)
