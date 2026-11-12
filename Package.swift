// swift-tools-version: 6.0
import PackageDescription

// App uses Kit; the run tool uses Kit; nothing depends on App.
//   PBSMackupKit    configuration, Keychain, APFS snapshot, client invocation, run state
//   pbs-mackup-run  performs one backup run and exits; started by launchd or by hand
//   PBSMackup       the menu bar app; reads the state file the run tool writes
let package = Package(
    name: "pbs-mackup",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PBSMackup", targets: ["App"]),
        .executable(name: "pbs-mackup-run", targets: ["RunTool"]),
        .library(name: "PBSMackupKit", targets: ["PBSMackupKit"]),
    ],
    targets: [
        .target(name: "PBSMackupKit"),
        .executableTarget(name: "RunTool", dependencies: ["PBSMackupKit"]),
        .executableTarget(name: "App", dependencies: ["PBSMackupKit"]),
        // RunTool is a dependency so that pbs-mackup-run is built before the tests that start it.
        .testTarget(name: "PBSMackupKitTests", dependencies: ["PBSMackupKit", "RunTool"]),
    ],
    swiftLanguageModes: [.v5]
)
