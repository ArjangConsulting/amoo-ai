// swift-tools-version: 6.2
import PackageDescription

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
        .library(name: "AuditEngine", targets: ["AuditEngine"]),
        .library(name: "CommandContract", targets: ["CommandContract"]),
        .library(name: "TestSession", targets: ["TestSession"]),
        .library(name: "OllamaClient", targets: ["OllamaClient"]),
        .executable(name: "amoo", targets: ["CLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/maniramezan/SwiftyShell.git", exact: "0.4.0"),
        .package(url: "https://github.com/ShipItSwifty/shipitswifty.git", exact: "0.3.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "CLIReadline",
            path: "Sources/CLIReadline",
            linkerSettings: [.linkedLibrary("edit", .when(platforms: [.macOS]))]
        ),
        .target(name: "AmooCore"),
        .target(
            name: "Protos",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
            ],
            path: "Protos",
            exclude: ["protoc"],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
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
                .product(name: "ShipItKit", package: "ShipItSwifty"),
                .product(name: "GradleKit", package: "ShipItSwifty")
            ]
        ),
        .target(name: "IOSDriver", dependencies: ["AmooCore", "CompanionProtocol", "ProcessRunner"]),
        .target(name: "AndroidDriver", dependencies: ["AmooCore", "CompanionProtocol", "ProcessRunner"]),
        .target(name: "AuditEngine", dependencies: ["AmooCore"]),
        .target(name: "CommandContract", dependencies: ["AmooCore"]),
        .target(name: "TestSession", dependencies: ["AmooCore"]),
        .target(name: "OllamaClient"),
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
                "TestSession",
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "CLIReadline",
                "AmooCore",
                "CompanionProtocol",
                "IOSDriver",
                "AndroidDriver",
                "MCPServer",
                "OllamaClient",
                "AuditEngine",
                "ProcessRunner",
                "TestSession",
                .product(name: "GradleKit", package: "ShipItSwifty"),
                .product(name: "XcodeBuildKit", package: "ShipItSwifty"),
                .product(name: "XcodeGenKit", package: "ShipItSwifty"),
                .product(name: "SwiftyShell", package: "SwiftyShell")
            ]
        ),
        .testTarget(name: "AmooCoreTests", dependencies: ["AmooCore"]),
        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(name: "IOSDriverTests", dependencies: ["IOSDriver"]),
        .testTarget(name: "AndroidDriverTests", dependencies: ["AndroidDriver"]),
        .testTarget(
            name: "ProcessRunnerTests",
            dependencies: [
                "ProcessRunner",
                .product(name: "SwiftyShell", package: "SwiftyShell")
            ]
        ),
        .testTarget(name: "GRPCServiceTests", dependencies: ["GRPCService"]),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer"]),
        .testTarget(name: "AuditEngineTests", dependencies: ["AuditEngine"]),
        .testTarget(name: "TestSessionTests", dependencies: ["TestSession", "AmooCore"]),
        .testTarget(name: "OllamaClientTests", dependencies: ["OllamaClient"]),
        .testTarget(
            name: "CLITests",
            dependencies: [
                "CLI",
                .product(name: "SwiftyShell", package: "SwiftyShell")
            ]
        ),
        .testTarget(name: "CommandContractTests", dependencies: ["CommandContract", "MCPServer"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "IOSDriver",
                "AndroidDriver",
                "CompanionProtocol",
                "MCPServer",
                "ProcessRunner",
                "CommandContract"
            ]
        )
    ]
)
