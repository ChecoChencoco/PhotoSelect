// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "PhotoSelect",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "PhotoSelect", targets: ["PhotoSelect"]),
               .executable(name: "PhotoSelectChecks", targets: ["PhotoSelectChecks"])],
    dependencies: [.package(path: "../Tools/RAWDecoderProbe")],
    targets: [
        .target(name: "PhotoSelectCore", dependencies: [.product(name: "ProbeCore", package: "RAWDecoderProbe")]),
        .executableTarget(name: "PhotoSelect", dependencies: ["PhotoSelectCore"]),
        .executableTarget(name: "PhotoSelectChecks", dependencies: ["PhotoSelectCore"])
    ],
    swiftLanguageModes: [.v5]
)
