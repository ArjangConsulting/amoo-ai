// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MobileTesting",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "MobileTestingCore", targets: ["MobileTestingCore"]),
        .library(name: "Protos", targets: ["Protos"]),
        .library(name: "CompanionProtocol", targets: ["CompanionProtocol"]),
        .library(name: "IOSDriver", targets: ["IOSDriver"]),
        .library(name: "AndroidDriver", targets: ["AndroidDriver"]),
        .library(name: "ProcessRunner", targets: ["ProcessRunner"]),
        .library(name: "GRPCService", targets: ["GRPCService"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "AuditEngine", targets: ["AuditEngine"]),
        .library(name: "CommandContract", targets: ["CommandContract"]),
        .executable(name: "mobile-testing", targets: ["CLI"])
    ],
    dependencies: [
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
        .target(name: "MobileTestingCore"),
        .target(
            name: "Protos",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf")
            ],
            path: "Protos",
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        .target(
            name: "CompanionProtocol",
            dependencies: [
                "MobileTestingCore",
                "Protos",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport")
            ]
        ),
        .target(name: "ProcessRunner", dependencies: ["MobileTestingCore"]),
        .target(name: "IOSDriver", dependencies: ["MobileTestingCore", "CompanionProtocol", "ProcessRunner"]),
        .target(name: "AndroidDriver", dependencies: ["MobileTestingCore", "CompanionProtocol", "ProcessRunner"]),
        .target(name: "AuditEngine", dependencies: ["MobileTestingCore"]),
        .target(name: "CommandContract", dependencies: ["MobileTestingCore"]),
        .target(
            name: "GRPCService",
            dependencies: [
                "MobileTestingCore",
                "CompanionProtocol",
                "IOSDriver",
                "AndroidDriver",
                "AuditEngine",
                "Protos"
            ]
        ),
        .target(name: "MCPServer", dependencies: ["MobileTestingCore", "GRPCService", "AuditEngine"]),
        .executableTarget(
            name: "CLI",
            dependencies: [
                "CLIReadline",
                "MobileTestingCore",
                "CompanionProtocol",
                "IOSDriver",
                "AndroidDriver",
                "MCPServer",
                "AuditEngine",
                "ProcessRunner"
            ]
        ),
        .testTarget(name: "MobileTestingCoreTests", dependencies: ["MobileTestingCore"]),
        .testTarget(name: "CompanionProtocolTests", dependencies: ["CompanionProtocol"]),
        .testTarget(name: "IOSDriverTests", dependencies: ["IOSDriver"]),
        .testTarget(name: "AndroidDriverTests", dependencies: ["AndroidDriver"]),
        .testTarget(name: "ProcessRunnerTests", dependencies: ["ProcessRunner"]),
        .testTarget(name: "GRPCServiceTests", dependencies: ["GRPCService"]),
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer"]),
        .testTarget(name: "AuditEngineTests", dependencies: ["AuditEngine"]),
        .testTarget(name: "CLITests", dependencies: ["CLI"]),
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
