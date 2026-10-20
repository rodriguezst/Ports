// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [.library(name: "PortsCore", targets: ["PortsCore"])]
var targets: [Target] = [
    .target(name: "PortsCore"),
    .testTarget(name: "PortsCoreTests", dependencies: ["PortsCore"])
]

#if os(macOS)
products.append(.executable(name: "Ports", targets: ["Ports"]))
targets.append(.executableTarget(name: "Ports", dependencies: ["PortsCore"]))
#endif

let package = Package(
    name: "Ports",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
