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
    .library(
      name: "ServeNIO",
      targets: ["ServeNIO"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/wuhu-labs/wuhu-fetch", .upToNextMinor(from: "0.2.0")),
    .package(url: "https://github.com/apple/swift-http-types.git", from: "1.3.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
  ],
  targets: [
    .target(
      name: "Serve",
      dependencies: [
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "ServeNIO",
      dependencies: [
        "Serve",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
    .testTarget(
      name: "ServeTests",
      dependencies: [
        "Serve",
        .product(name: "Fetch", package: "wuhu-fetch"),
      ]
    ),
    .testTarget(
      name: "ServeNIOTests",
      dependencies: [
        "ServeNIO",
        .product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch"),
      ]
    ),
  ]
)
