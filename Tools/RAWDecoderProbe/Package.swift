// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RAWDecoderProbe",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "RAWDecoderProbe", targets: ["RAWDecoderProbe"]),
               .library(name: "ProbeCore", targets: ["ProbeCore"])],
    targets: [
        .target(name: "ProbeCore"),
        .executableTarget(name: "RAWDecoderProbe", dependencies: ["ProbeCore"]),
        .executableTarget(name: "ProbeCoreChecks", dependencies: ["ProbeCore"], path: "Tests/ProbeCoreChecks")
    ]
)
