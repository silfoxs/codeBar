// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "codeBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "codeBar", targets: ["codeBar"])],
    targets: [
        .executableTarget(name: "codeBar", resources: [.process("Resources")]),
        .testTarget(name: "codeBarTests", dependencies: ["codeBar"])
    ]
)
