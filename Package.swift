// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AIQuota",
  platforms: [.macOS(.v14)],
  products: [.executable(name: "AIQuota", targets: ["AIQuota"])],
  targets: [
    .target(name: "QuotaCore"),
    .executableTarget(name: "AIQuota", dependencies: ["QuotaCore"]),
    .testTarget(
      name: "QuotaCoreTests", dependencies: ["QuotaCore"], resources: [.copy("Fixtures")]),
  ]
)
