// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "wuhu-serve",
  platforms: [
    .iOS(.v13),
    .macOS(.v10_15),
    .tvOS(.v13),
    .watchOS(.v6),
  ],
  products: [
    .library(
      name: "Serve",
      targets: ["Serve"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch", branch: "main"),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "Serve",
      dependencies: [
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .testTarget(
      name: "ServeTests",
      dependencies: ["Serve"]
    ),
  ]
)
