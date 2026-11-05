// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "tracive_sdk",
  platforms: [
    .iOS("12.0")
  ],
  products: [
    .library(name: "tracive-sdk", targets: ["tracive_sdk"])
  ],
  dependencies: [],
  targets: [
    .target(
      name: "tracive_sdk",
      dependencies: []
    )
  ]
)
