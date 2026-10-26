// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Spacer",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "Spacer", targets: ["Spacer"]),
    .library(name: "SpacerCore", targets: ["SpacerCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
  ],
  targets: [
    .target(name: "SpacerCore"),
    .executableTarget(
      name: "Spacer",
      dependencies: ["SpacerCore", .product(name: "Sparkle", package: "Sparkle")],
      // scripts/bundle.sh puts Sparkle.framework in Contents/Frameworks.
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(name: "SpacerCoreTests", dependencies: ["SpacerCore"]),
  ]
)
