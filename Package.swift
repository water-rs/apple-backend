// swift-tools-version: 6.3.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "waterui-swift",
  platforms: [
    .iOS(.v26),
    .macOS(.v26),
    .watchOS(.v26),
  ],
  products: [
    .library(name: "WaterUI", targets: ["WaterUI"]),
    .library(name: "WaterUICEF", targets: ["WaterUICEF"]),
    .library(name: "WaterUIChromium", targets: ["WaterUIChromium"]),
    .library(name: "WaterUICefWebView", targets: ["WaterUICefWebView"]),
  ],
  targets: [
    .target(name: "CWaterUI"),
    .target(
      name: "WaterUI",
      dependencies: ["CWaterUI"],
      resources: [.process("Resources")]
    ),
    .target(
      name: "WaterUICEF",
      dependencies: ["CWaterUI", "WaterUI"]
    ),
    .target(
      name: "WaterUIChromium",
      dependencies: ["CWaterUI", "WaterUI", "WaterUICEF"]
    ),
    .target(
      name: "WaterUICefWebView",
      dependencies: ["CWaterUI", "WaterUI", "WaterUICEF"]
    ),
  ]
)
