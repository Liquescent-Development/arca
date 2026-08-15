// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Arca",
    platforms: [
        .macOS("26.0")  // macOS Sequoia
    ],
    dependencies: [
        .package(path: "containerization"),  // Use local containerization submodule
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.87.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        // grpc-swift-2 is reached only transitively, through the containerization
        // submodule (containerization/Package.swift declares it `from: "2.3.0"`).
        // It is constrained here, at the root, because 2.4.x declares `traits: []`
        // on swift-protobuf, and swift-protobuf 1.32.0 declares no traits at all --
        // a combination Swift 6.3.3 rejects outright:
        //
        //   error: Disabled default traits by package 'grpc-swift-2' on package
        //   'swift-protobuf' that declares no traits.
        //
        // The failure only appears when building an EXECUTABLE PRODUCT from a clean
        // checkout; building library targets resolves without it, which is why this
        // stayed hidden until Gas Can's pinned build began producing a binary.
        // Remove this constraint once swift-protobuf declares traits.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", "2.3.0" ..< "2.4.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        // Main executable target
        .executableTarget(
            name: "Arca",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "ArcaDaemon",
            ]
        ),

        // Test helper executable (requires signing with entitlements)
        .executableTarget(
            name: "ArcaTestHelper",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ContainerBridge",
            ]
        ),

        // Daemon server (HTTP/Unix socket server)
        .target(
            name: "ArcaDaemon",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                // ArcaDaemon.swift imports Containerization directly, for
                // ImageStore.default.path. Declared rather than left to reach
                // the module transitively through ContainerBridge: a transitive
                // import compiles until ContainerBridge stops depending on
                // Containerization, and then the breakage lands on whoever
                // edited ContainerBridge rather than here.
                .product(name: "Containerization", package: "containerization"),
                "DockerAPI",
                "ContainerBridge",
            ]
        ),

        // Docker API models and handlers
        .target(
            name: "DockerAPI",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SWCompression", package: "SWCompression"),
                "ContainerBridge",
            ]
        ),

        // Apple Containerization API wrapper
        .target(
            name: "ContainerBridge",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SQLite", package: "SQLite.swift"),
                "ArcaIP",
            ]
        ),

        // Generated server code for the published sandbox-engine contract,
        // proto/arca/engine/v1/engine.proto. Its own target, not part of
        // ContainerBridge, for the same reason the proto sits at the repository
        // root rather than beside the guest-facing ones: a contract published to
        // consumers is not a ContainerBridge internal. Regenerate with
        // scripts/generate-grpc.sh; do not hand-edit the generated files.
        //
        // Nothing depends on this target yet. That is deliberate — P3's exit is
        // "proto exists, both sides generate, nothing implements it yet" — but
        // `swift build` still compiles it, so the generated code is proven to
        // build rather than merely proven to have been emitted.
        .target(
            name: "SandboxEngineProto",
            dependencies: [
                .product(name: "GRPC", package: "grpc-swift"),
            ]
        ),

        // Gas Can's sandbox engine. Deliberately does NOT depend on DockerAPI or
        // ArcaDaemon: Gas Can builds only the targets it ships, and that absent
        // edge is asserted by gascan's tests/release/engine-targets-check.sh,
        // which walks the closure of both this target and the arca-engine
        // executable below -- the executable is what Gas Can actually ships, so
        // checking only this one would leave the shipped binary uncovered.
        .target(
            name: "ArcaEngine",
            dependencies: [
                "SandboxEngineProto",
                "ContainerBridge",
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        .testTarget(
            name: "ArcaEngineTests",
            dependencies: ["ArcaEngine"]
        ),

        // The `arca-engine` executable: binds SandboxEngineService to a Unix
        // socket. Deliberately does NOT depend on DockerAPI or ArcaDaemon, for
        // the same reason ArcaEngine itself does not.
        .executableTarget(
            name: "arca-engine",
            dependencies: [
                "ArcaEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // Internal IPv4/CIDR types. Zero dependencies by design: this target
        // replaced swift-ip, whose transitive graph pinned commits that no
        // longer exist upstream and made the tree impossible to build cold.
        // Adding a dependency here would forfeit that property.
        .target(name: "ArcaIP"),

        .testTarget(
            name: "ArcaIPTests",
            dependencies: ["ArcaIP"]
        ),

        // Tests
        .testTarget(
            name: "ArcaTests",
            dependencies: [
                "Arca",
                "ArcaDaemon",
                "DockerAPI",
                "ContainerBridge",
            ]
        ),
    ]
)
