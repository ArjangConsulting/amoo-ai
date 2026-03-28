---
name: grpc-swift
description: Guide for building gRPC services in Swift using grpc-swift v2 — proto design, code generation, server/client patterns, streaming RPCs, transport configuration, and Package.swift setup.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-05 |
| grpc-swift | v2.x (grpc-swift-2 repo) |
| grpc-swift v1 | 1.27.3 (maintenance mode — bug/security fixes only) |
| Swift | 6.0+ required for v2 |
| macOS | 15.0+ for v2 |
| Source repos | [grpc-swift-2](https://github.com/grpc/grpc-swift-2), [grpc-swift-protobuf](https://github.com/grpc/grpc-swift-protobuf), [grpc-swift-nio-transport](https://github.com/grpc/grpc-swift-nio-transport) |

### Update checklist
- [ ] Check [grpc-swift-2 releases](https://github.com/grpc/grpc-swift-2/releases) for new versions
- [ ] Check [grpc-swift-protobuf releases](https://github.com/grpc/grpc-swift-protobuf/releases) for codegen changes
- [ ] Review [grpc-swift-nio-transport releases](https://github.com/grpc/grpc-swift-nio-transport/releases) for transport updates
- [ ] Check Swift version compatibility matrix (v2 drops older Swift versions aggressively)
- [ ] Review examples in grpc-swift-2/Examples/ for API changes

# gRPC Swift Skill

Guide for building gRPC services in Swift using the v2 API with Protocol Buffers, SwiftNIO transport, and Swift's native async/await concurrency.

## When to use

Use this skill when:
- Defining gRPC service contracts with .proto files
- Setting up gRPC servers or clients in Swift
- Implementing unary, streaming, or bidirectional RPCs
- Configuring transport, security, and interceptors
- Integrating gRPC into a Swift Package Manager project

## Project Alignment (mobile-testing repo)

Use these conventions in this repository:

- Keep proto contracts in top-level `Protos/` with a dedicated SwiftPM target named `Protos` (path-based target).
- Use package `mobile.testing.v1` and `option swift_prefix = "MobileTesting_"`.
- Split contracts by domain files:
  - `actions.proto` (companion interaction/session RPCs)
  - `accessibility.proto` (tree/query/wait RPCs)
  - `ai.proto` (AI context and semantic lookup RPCs)
  - `device.proto` (host lifecycle/config RPCs exposed externally)
  - `common.proto` (shared messages/enums)
- Include capability negotiation (`StartSession`, `GetCapabilities`, `EndSession`) in companion contracts.
- Keep host-owned lifecycle/config operations out of companion-only RPC surfaces.

## Important: v2 vs v1

**Always use grpc-swift v2** (the `grpc-swift-2` repo). v1 is in maintenance mode.

Key differences:
- v2 is split into multiple packages (core, transport, protobuf)
- v2 uses Swift's native async/await (no Combine or EventLoopFuture)
- v2 requires Swift 6.0+ and macOS 15.0+
- v2 uses a build plugin for proto code generation (no separate `protoc` step)

## Package.swift Setup

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyGRPCService",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MyService",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf"),
            ]
        ),
    ]
)
```

**Key points:**
- Three separate package dependencies (core, transport, protobuf)
- The `GRPCProtobufGenerator` build plugin auto-generates Swift code from .proto files
- No need to manually run `protoc` — the plugin handles it during build

## Proto File Setup

Place `.proto` files in your target's `Sources/Protos/` directory (or any subdirectory). The build plugin discovers them automatically.

### Example proto file

```protobuf
syntax = "proto3";

package myservice;

option swift_prefix = "MyService_";

service DeviceDriver {
    // Unary RPC
    rpc TakeScreenshot (ScreenshotRequest) returns (ScreenshotResponse);

    // Server streaming
    rpc StreamLogs (LogRequest) returns (stream LogEntry);

    // Client streaming
    rpc UploadFiles (stream FileChunk) returns (UploadResult);

    // Bidirectional streaming
    rpc InteractiveSession (stream Command) returns (stream CommandResult);
}

message ScreenshotRequest {
    string device_id = 1;
    string format = 2;  // "png", "jpeg"
}

message ScreenshotResponse {
    bytes image_data = 1;
    int32 width = 2;
    int32 height = 3;
}

message LogRequest {
    string device_id = 1;
    string filter = 2;
    LogLevel min_level = 3;
}

enum LogLevel {
    LOG_LEVEL_UNSPECIFIED = 0;
    LOG_LEVEL_DEBUG = 1;
    LOG_LEVEL_INFO = 2;
    LOG_LEVEL_WARNING = 3;
    LOG_LEVEL_ERROR = 4;
}

message LogEntry {
    string timestamp = 1;
    LogLevel level = 2;
    string message = 3;
    string source = 4;
}

message FileChunk {
    string filename = 1;
    bytes data = 2;
    bool is_last = 3;
}

message UploadResult {
    int32 files_received = 1;
    int64 total_bytes = 2;
}

message Command {
    string action = 1;      // "tap", "swipe", "type", etc.
    map<string, string> parameters = 2;
}

message CommandResult {
    bool success = 1;
    string output = 2;
    bytes screenshot = 3;  // optional post-action screenshot
}
```

### Proto design best practices

- Use `proto3` syntax (not proto2)
- Set `option swift_prefix` to namespace generated types
- Use meaningful package names to avoid collisions
- Define enums with `_UNSPECIFIED = 0` as the default
- Use `bytes` for binary data (screenshots, files)
- Use `map<string, string>` for flexible key-value parameters
- Keep messages focused — one responsibility per message
- Use `stream` keyword for streaming RPCs

## Server Implementation

### Basic server setup

```swift
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

// The generated code creates a protocol: MyService_DeviceDriver.SimpleServiceProtocol
struct DeviceDriverService: MyService_DeviceDriver.SimpleServiceProtocol {

    // Unary RPC
    func takeScreenshot(
        request: MyService_ScreenshotRequest,
        context: ServerContext
    ) async throws -> MyService_ScreenshotResponse {
        // Implementation here
        return .with {
            $0.imageData = capturedData
            $0.width = 1170
            $0.height = 2532
        }
    }

    // Server streaming RPC
    func streamLogs(
        request: MyService_LogRequest,
        response: RPCWriter<MyService_LogEntry>,
        context: ServerContext
    ) async throws {
        // Write multiple responses
        for await logLine in getLogStream(deviceId: request.deviceID) {
            try await response.write(.with {
                $0.timestamp = logLine.timestamp
                $0.level = logLine.level
                $0.message = logLine.message
            })
        }
    }

    // Client streaming RPC
    func uploadFiles(
        request: RPCAsyncSequence<MyService_FileChunk>,
        context: ServerContext
    ) async throws -> MyService_UploadResult {
        var totalBytes: Int64 = 0
        var fileCount: Int32 = 0
        for try await chunk in request {
            totalBytes += Int64(chunk.data.count)
            if chunk.isLast { fileCount += 1 }
        }
        return .with {
            $0.filesReceived = fileCount
            $0.totalBytes = totalBytes
        }
    }

    // Bidirectional streaming RPC
    func interactiveSession(
        request: RPCAsyncSequence<MyService_Command>,
        response: RPCWriter<MyService_CommandResult>,
        context: ServerContext
    ) async throws {
        for try await command in request {
            let result = try await executeCommand(command)
            try await response.write(result)
        }
    }
}
```

### Starting the server

```swift
func startServer(port: Int = 50051) async throws {
    let server = GRPCServer(
        transport: .http2NIOPosix(
            address: .ipv4(host: "127.0.0.1", port: port),
            transportSecurity: .plaintext
        ),
        services: [DeviceDriverService()]
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await server.serve()
        }
        // Server is running — add other tasks or wait
        print("Server listening on port \(port)")

        // Keep running until cancelled
        try await group.next()
    }
}
```

## Client Implementation

### Basic client usage

```swift
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf

func makeClient() async throws {
    try await withGRPCClient(
        transport: .http2NIOPosix(
            target: .dns(host: "localhost", port: 50051),
            transportSecurity: .plaintext
        )
    ) { client in
        let driver = MyService_DeviceDriver.Client(wrapping: client)

        // Unary call
        let screenshot = try await driver.takeScreenshot(
            .with { $0.deviceID = "emulator-5554" }
        )
        print("Got screenshot: \(screenshot.width)x\(screenshot.height)")
    }
}
```

### Streaming client patterns

```swift
// Server streaming — receive multiple responses
try await driver.streamLogs(
    .with {
        $0.deviceID = "booted"
        $0.minLevel = .info
    }
) { response in
    for try await entry in response.messages {
        print("[\(entry.level)] \(entry.message)")
    }
}

// Client streaming — send multiple requests, get one response
let result = try await driver.uploadFiles { writer in
    for file in filesToUpload {
        for chunk in file.chunks {
            try await writer.write(.with {
                $0.filename = file.name
                $0.data = chunk.data
                $0.isLast = chunk.isLast
            })
        }
    }
}
print("Uploaded \(result.filesReceived) files")

// Bidirectional streaming — send and receive concurrently
try await driver.interactiveSession { writer in
    // Send commands
    try await writer.write(.with {
        $0.action = "tap"
        $0.parameters = ["x": "500", "y": "1200"]
    })
    try await writer.write(.with {
        $0.action = "type"
        $0.parameters = ["text": "hello"]
    })
} onResponse: { response in
    // Receive results
    for try await result in response.messages {
        print("Action result: \(result.success) - \(result.output)")
    }
}
```

## Message Construction

gRPC-Swift v2 uses the `.with { }` pattern from SwiftProtobuf:

```swift
// Create a message
let request = MyService_ScreenshotRequest.with {
    $0.deviceID = "booted"
    $0.format = "png"
}

// Nested messages
let command = MyService_Command.with {
    $0.action = "swipe"
    $0.parameters = [
        "x1": "500",
        "y1": "1500",
        "x2": "500",
        "y2": "500",
        "duration": "300"
    ]
}
```

## Transport Configuration

### Plaintext (development)

```swift
// Server
.http2NIOPosix(
    address: .ipv4(host: "127.0.0.1", port: 50051),
    transportSecurity: .plaintext
)

// Client
.http2NIOPosix(
    target: .dns(host: "localhost", port: 50051),
    transportSecurity: .plaintext
)
```

### TLS (production)

```swift
// Server with TLS
.http2NIOPosix(
    address: .ipv4(host: "0.0.0.0", port: 443),
    transportSecurity: .tls(
        certificateChain: [.certificate(serverCert)],
        privateKey: .privateKey(serverKey)
    )
)

// Client with TLS
.http2NIOPosix(
    target: .dns(host: "api.example.com", port: 443),
    transportSecurity: .tls(
        certificateVerification: .fullVerification
    )
)
```

### Address types

```swift
// IPv4
.ipv4(host: "127.0.0.1", port: 50051)

// IPv6
.ipv6(host: "::1", port: 50051)

// Unix domain socket (good for local IPC)
.unixDomainSocket(path: "/tmp/myservice.sock")

// Client targets
.dns(host: "localhost", port: 50051)
.ipv4(host: "127.0.0.1", port: 50051)
.unixDomainSocket(path: "/tmp/myservice.sock")
```

## Error Handling

```swift
// Server: throw RPCError for gRPC-level errors
func takeScreenshot(
    request: MyService_ScreenshotRequest,
    context: ServerContext
) async throws -> MyService_ScreenshotResponse {
    guard !request.deviceID.isEmpty else {
        throw RPCError(code: .invalidArgument, message: "device_id is required")
    }
    guard let device = findDevice(request.deviceID) else {
        throw RPCError(code: .notFound, message: "Device not found: \(request.deviceID)")
    }
    // ...
}

// Client: catch RPCError
do {
    let response = try await driver.takeScreenshot(request)
} catch let error as RPCError {
    switch error.code {
    case .notFound:
        print("Device not found")
    case .invalidArgument:
        print("Invalid request: \(error.message)")
    case .unavailable:
        print("Server unavailable")
    default:
        print("RPC failed: \(error.code) - \(error.message)")
    }
}
```

### Common gRPC status codes

| Code | Use case |
|------|----------|
| `.ok` | Success |
| `.invalidArgument` | Bad request parameters |
| `.notFound` | Resource doesn't exist |
| `.alreadyExists` | Resource already exists |
| `.permissionDenied` | Not authorized |
| `.unavailable` | Server temporarily unavailable |
| `.unimplemented` | RPC not implemented |
| `.internal` | Unexpected server error |
| `.deadlineExceeded` | Timeout |
| `.cancelled` | Client cancelled the RPC |

## Project Structure

Recommended layout for a gRPC Swift project:

```
MyGRPCService/
├── Package.swift
├── Sources/
│   ├── Protos/                    # .proto files (auto-discovered by plugin)
│   │   ├── device_driver.proto
│   │   └── common.proto
│   ├── Server/
│   │   ├── main.swift
│   │   └── DeviceDriverService.swift
│   └── Client/
│       └── DeviceDriverClient.swift
└── Tests/
    └── MyGRPCServiceTests/
        └── DeviceDriverTests.swift
```

## Testing gRPC Services

```swift
import Testing
import GRPCCore

@Test func testTakeScreenshot() async throws {
    let service = DeviceDriverService()
    // Create a mock context or use in-process transport for testing
    let request = MyService_ScreenshotRequest.with {
        $0.deviceID = "test-device"
        $0.format = "png"
    }
    // Direct service method call (unit test)
    // For integration tests, use in-process transport
}
```

## Build and Run

```bash
# Build
swift build

# Run server
swift run MyService serve --port 50051

# Run client
swift run MyService greet --name "World"

# Clean generated code (regenerates on next build)
swift package clean
```

## Proto Code Generation Details

The `GRPCProtobufGenerator` build plugin:
- Scans for `.proto` files in the target's source directory
- Generates Swift types for messages (e.g., `MyService_ScreenshotRequest`)
- Generates service protocols (e.g., `MyService_DeviceDriver.SimpleServiceProtocol`)
- Generates client stubs (e.g., `MyService_DeviceDriver.Client`)
- Output goes to the build directory (not checked into source)
- Regenerates automatically when `.proto` files change

No manual `protoc` installation or invocation needed.
