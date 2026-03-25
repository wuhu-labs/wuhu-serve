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
      name: "ServeSSE",
      targets: ["ServeSSE"]
    ),
    .library(
      name: "ServeRouting",
      targets: ["ServeRouting"]
    ),
    .library(
      name: "ServeFiles",
      targets: ["ServeFiles"]
    ),
    .library(
      name: "ServeTesting",
      targets: ["ServeTesting"]
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
      name: "ServeRouting",
      dependencies: [
        "Serve",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "ServeSSE",
      dependencies: [
        "Serve",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .target(
      name: "ServeFiles",
      dependencies: [
        "Serve",
        "ServeRouting",
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
    .target(
      name: "ServeTesting",
      dependencies: [
        "Serve",
        .product(name: "Fetch", package: "wuhu-fetch"),
      ]
    ),
    .testTarget(
      name: "ServeTests",
      dependencies: [
        "Serve",
        "ServeTesting",
        .product(name: "Fetch", package: "wuhu-fetch"),
      ]
    ),
    .testTarget(
      name: "ServeRoutingTests",
      dependencies: [
        "ServeRouting",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .testTarget(
      name: "ServeSSETests",
      dependencies: [
        "ServeSSE",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .testTarget(
      name: "ServeFilesTests",
      dependencies: [
        "ServeFiles",
        "ServeRouting",
        .product(name: "Fetch", package: "wuhu-fetch"),
        .product(name: "HTTPTypes", package: "swift-http-types"),
      ]
    ),
    .testTarget(
      name: "ServeNIOTests",
      dependencies: [
        "ServeNIO",
        .product(name: "FetchAsyncHTTPClient", package: "wuhu-fetch"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]
    ),
  ]
)
