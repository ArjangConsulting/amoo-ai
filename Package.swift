// swift-tools-version: 6.2
import PackageDescription

/// The generated protobuf/gRPC Swift is committed in `Sources/Protos/Generated`. The
/// `GRPCProtobufGenerator` build plugin depends on swift-protobuf's `protoc` product, which SwiftPM
/// compiles from ~1,500 C++ files (3-6 min, every clean build, on every platform) even when
/// `PROTOC_PATH` points at a prebuilt protoc. So normal builds skip the plugin entirely. Regenerate
/// with `make protos`, which sets this flag to add the `ProtosGenerator` target below.
let regenerateProtos = Context.environment["AMOO_REGENERATE_PROTOS"] == "1"

let package = Package(
    name: "Amoo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "AmooCore", targets: ["AmooCore"]),
        .library(name: "Protos", targets: ["Protos"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
        .library(name: "IOSDriver", targets: ["IOSDriver"]),
        .library(name: "AndroidDriver", targets: ["AndroidDriver"]),
        .library(name: "ProcessRunner", targets: ["ProcessRunner"]),
        .library(name: "GRPCService", targets: ["GRPCService"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "WebInspector", targets: ["WebInspector"]),
        .library(name: "AuditEngine", targets: ["AuditEngine"]),
        .library(name: "CommandContract", targets: ["CommandContract"]),
        .library(name: "TestSession", targets: ["TestSession"]),
        .library(name: "SessionCompiler", targets: ["SessionCompiler"]),
        .library(name: "OllamaClient", targets: ["OllamaClient"]),
        .library(name: "StudioProtocol", targets: ["StudioProtocol"]),
        .library(name: "TestCodeGenerator", targets: ["TestCodeGenerator"]),
        .executable(name: "amoo", targets: ["CLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        .package(url: "https://github.com/maniramezan/SwiftTestCommons.git", from: "0.3.0"),
        // AmooLogging's Linux backend; Apple platforms log through OSLog.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.1"),
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", from: "0.7.0"),
        // Prompts, progress, styling and line editing shared with ShipItSwifty. Tracks main until 0.1.0.
        .package(url: "https://github.com/maniramezan/SwiftyTerminal.git", branch: "main"),
        // Typed tool wrappers (xcrun/simctl, Gradle, adb, …). Tracks main until it reaches 1.0.
        .package(url: "https://github.com/ShipItSwifty/cli-wrappers.git", branch: "main"),
        // Device, build, test, and inspection mechanisms shared with ShipItSwifty. Tracks main until 1.0.
        .package(url: "https://github.com/ShipItSwifty/mobile-kits.git", branch: "main"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin.git", from: "1.5.0")
    ],
    targets: [
        .target(
            name: "AmooCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            plugins: [.plugin(name: "BuildProvenancePlugin")]
        ),
        .plugin(name: "BuildProvenancePlugin", capability: .buildTool(), path: "BuildPlugins/BuildProvenancePlugin"),
        .target(
            name: "AmooLogging",
            dependencies: [
                .product(name: "Logging", package: "swift-log", condition: .when(platforms: [.linux]))
            ]
        ),
        .target(
            name: "Protos",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
            ]
        ),
        .target(
            name: "CompanionProtocol",
            dependencies: [
                "AmooCore",
                "Protos",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")
            ]
        ),
        .target(
            name: "ProcessRunner",
            dependencies: [
                "AmooCore",
                .product(name: "SwiftyShell", package: "SwiftyShell"),
                .product(name: "XcrunKit", package: "cli-wrappers"),
                .product(name: "DeviceCtlKit", package: "cli-wrappers"),
                .product(name: "IProxyKit", package: "cli-wrappers"),
                .product(name: "GradleKit", package: "cli-wrappers"),
                .product(name: "AdbKit", package: "cli-wrappers"),
                .product(name: "AVDManagerKit", package: "cli-wrappers"),
                .product(name: "AndroidCLIKit", package: "cli-wrappers"),
                .product(name: "MobileCore", package: "mobile-kits"),
                .product(name: "MobileDevices", package: "mobile-kits")
            ]
        ),
        .target(name: "WebInspector"),
        .target(name: "IOSDriver", dependencies: ["AmooCore", "CompanionProtocol", "ProcessRunner"]),
        .target(
            name: "AndroidDriver",
            dependencies: [
                "AmooCore", "CompanionProtocol", "ProcessRunner",
                .product(name: "MobileDevices", package: "mobile-kits")
            ]
        ),
        .target(name: "AuditEngine", dependencies: ["AmooCore"]),
        .target(name: "CommandContract", dependencies: ["AmooCore"]),
        .target(name: "TestSession", dependencies: ["AmooCore"]),
        .target(name: "SessionCompiler", dependencies: ["AmooCore", "StudioProtocol", "TestSession"]),
        .target(name: "OllamaClient"),
        .target(name: "StudioProtocol", dependencies: ["AmooCore", "ProcessRunner"]),
        .target(name: "TestCodeGenerator", dependencies: ["StudioProtocol"]),
        .target(
            name: "GRPCService",
            dependencies: [
                "AmooCore",
                "CompanionProtocol",
                "IOSDriver",
                "AndroidDriver",
                "AuditEngine",
                "Protos"
            ]
        ),
        .target(
            name: "MCPServer",
            dependencies: [
                "AmooCore",
                "GRPCService",
                "AuditEngine",
                "ProcessRunner",
                "TestSession",
                "SessionCompiler",
                "StudioProtocol",
                "WebInspector",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SwiftyTerminal", package: "SwiftyTerminal")
            ]
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "AmooCore",
                "CompanionProtocol",
                "IOSDriver",
                "AndroidDriver",
                "MCPServer",
                "OllamaClient",
                "AuditEngine",
                "ProcessRunner",
                "TestSession",
                "SessionCompiler",
                "StudioProtocol",
                "TestCodeGenerator",
                "WebInspector",
                .product(name: "AdbKit", package: "cli-wrappers"),
                .product(name: "XcrunKit", package: "cli-wrappers"),
                .product(name: "GradleKit", package: "cli-wrappers"),
                .product(name: "XcodeBuildKit", package: "cli-wrappers"),
                .product(name: "XcodeGenKit", package: "cli-wrappers"),
                .product(name: "MobileCore", package: "mobile-kits"),
                .product(name: "MobileDevices", package: "mobile-kits"),
                .product(name: "MobileProject", package: "mobile-kits"),
                .product(name: "SwiftyShell", package: "SwiftyShell"),
                .product(name: "SwiftyTerminal", package: "SwiftyTerminal"),
                .product(name: "SwiftyTerminalLineEditor", package: "SwiftyTerminal"),
                "AmooLogging"
            ]
        ),
        .testTarget(
            name: "AmooCoreTests",
            dependencies: ["AmooCore", .product(name: "TestCommons", package: "SwiftTestCommons")]
        ),
        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(name: "IOSDriverTests", dependencies: ["IOSDriver"]),
        .testTarget(
            name: "AndroidDriverTests",
            dependencies: [
                "AndroidDriver",
                .product(name: "MobileDevices", package: "mobile-kits"),
                .product(name: "TestCommons", package: "SwiftTestCommons")
            ]
        ),
        .testTarget(
            name: "ProcessRunnerTests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"),
                "ProcessRunner",
                .product(name: "SwiftyShell", package: "SwiftyShell")
            ]
        ),
        .testTarget(name: "GRPCServiceTests", dependencies: ["GRPCService"]),
        .testTarget(
            name: "MCPServerTests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"), "MCPServer", "SessionCompiler",
                "ProcessRunner", "WebInspector", "TestCodeGenerator"
            ]
        ),
        .testTarget(name: "WebInspectorTests", dependencies: ["WebInspector"]),
        .testTarget(name: "AuditEngineTests", dependencies: ["AuditEngine"]),
        .testTarget(
            name: "TestSessionTests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"), "TestSession", "AmooCore"
            ]
        ),
        .testTarget(name: "OllamaClientTests", dependencies: ["OllamaClient"]),
        .testTarget(
            name: "StudioProtocolTests",
            dependencies: ["StudioProtocol", .product(name: "TestCommons", package: "SwiftTestCommons")]
        ),
        .testTarget(
            name: "TestCodeGeneratorTests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"), "TestCodeGenerator",
                "StudioProtocol"
            ],
            exclude: ["Fixtures"]
        ),
        .testTarget(
            name: "CLITests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"),
                "CLI",
                "OllamaClient",
                "MCPServer",
                .product(name: "SwiftyShell", package: "SwiftyShell"),
                .product(name: "MobileCore", package: "mobile-kits"),
                .product(name: "MobileDevices", package: "mobile-kits")
            ]
        ),
        .testTarget(name: "CommandContractTests", dependencies: ["CommandContract", "MCPServer"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                .product(name: "TestCommons", package: "SwiftTestCommons"),
                "IOSDriver",
                "AndroidDriver",
                "CompanionProtocol",
                "MCPServer",
                "ProcessRunner",
                "CommandContract",
                "TestSession",
                "SessionCompiler",
                "StudioProtocol",
                "TestCodeGenerator"
            ]
        )
    ]
)

if regenerateProtos {
    // Runs the plugin over `Protos/*.proto` (the shared companion contract) so
    // scripts/regenerate-protos.sh can copy its output into `Sources/Protos/Generated`.
    package.targets.append(
        .target(
            name: "ProtosGenerator",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
            ],
            path: "Protos",
            exclude: ["protoc"],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        )
    )
}
