---
name: swift-package-architecture
description: Guide for designing multi-target Swift packages with protocol-oriented interfaces, platform-specific implementations, dependency management, plugins, testing, and modular architecture patterns.
---

## Version Info

| Field | Value |
|-------|-------|
| Created | 2026-03-04 |
| Last Updated | 2026-03-05 |
| Swift | 6.2.4 |
| swift-tools-version | 6.0 |
| SwiftPM | Swift Package Manager - Swift 6.2.4 |
| Source | `swift package --help`, swift.org docs |

### Update checklist
- [ ] Check `swift --version` and update Swift version
- [ ] Run `swift package init --help` for new target types
- [ ] Check [Swift Evolution proposals](https://github.com/swiftlang/swift-evolution) for SwiftPM changes
- [ ] Check [Swift blog](https://www.swift.org/blog/) for new Swift releases
- [ ] Review new `swift-tools-version` features in each Swift release
- [ ] Check if new target types (macro, plugin, etc.) have been added

# Swift Package Architecture Skill

Guide for structuring Swift packages with modular, testable, multi-platform architectures using Swift Package Manager.

## When to use

Use this skill when:
- Setting up a new Swift package with multiple targets
- Designing protocol-oriented interfaces with platform-specific implementations
- Configuring dependencies, plugins, and build settings
- Creating testable, mockable module boundaries
- Structuring a cross-platform (iOS/macOS/Linux) project

## Project Alignment (mobile-testing repo)

Current package conventions in this repository:

- Swift tools: `6.0`; platform baseline: `macOS 15`.
- Phase-2 contract/codegen setup:
  - `Protos/` directory is a dedicated target (`.target(name: "Protos", path: "Protos")`).
  - Attach `GRPCProtobufGenerator` plugin to `Protos`.
  - Runtime deps for generated code: `GRPCCore`, `GRPCProtobuf`.
- Target layering:
  - `AmooCore` is dependency root.
  - `CompanionProtocol` and `GRPCService` depend on `Protos`.
  - Drivers depend on core + companion protocol + process runner.
  - CLI depends on MCP + drivers + audit engine.
- CI quality gates are mandatory:
  - `swiftformat --lint`
  - `swiftlint --strict --no-cache`
  - coverage thresholds (`AmooCore >= 85%`, driver/protocol >= 75%, repo >= 80%).

## Package.swift Fundamentals

### swift-tools-version

The tools version determines available API. Always use the latest stable:

```swift
// swift-tools-version: 6.0
```

Key version milestones:
- **5.4**: `executableTarget`, package plugins
- **5.5**: `@available` in Package.swift, `#if` conditions
- **5.7**: Package plugins (build tool + command)
- **5.9**: Macros, Swift Testing support
- **6.0**: Swift 6 language mode, strict concurrency, traits

### Package init commands

```bash
# Library package
swift package init --name MyPackage --type library

# Executable
swift package init --name MyTool --type executable

# CLI tool (with ArgumentParser template)
swift package init --name MyCLI --type tool

# Build tool plugin
swift package init --name MyPlugin --type build-tool-plugin

# Command plugin
swift package init --name MyCommand --type command-plugin

# Macro
swift package init --name MyMacro --type macro

# Empty (just Package.swift)
swift package init --name MyPackage --type empty

# With Swift Testing enabled (default in 6.x)
swift package init --enable-swift-testing
```

### Package management commands

```bash
# Build
swift build
swift build -c release

# Test
swift test
swift test --filter MyModuleTests

# Run executable target
swift run MyTool

# Show dependency graph
swift package show-dependencies --format json

# Update dependencies
swift package update

# Resolve (without updating)
swift package resolve

# Clean build artifacts
swift package clean

# Full reset (clean + caches)
swift package reset

# Add dependency via CLI
swift package add-dependency https://github.com/example/package --from 1.0.0

# Add target via CLI
swift package add-target MyNewTarget --type library

# Dump package description as JSON
swift package dump-package

# Diagnose API-breaking changes
swift package diagnose-api-breaking-changes
```

## Multi-Target Architecture

### Interface + Implementation pattern

This is the core pattern for cross-platform code with platform-specific implementations:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmooFramework",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        // Public API that consumers depend on
        .library(name: "AmooCore", targets: ["AmooCore"]),

        // Platform-specific drivers
        .library(name: "IOSDriver", targets: ["IOSDriver"]),
        .library(name: "AndroidDriver", targets: ["AndroidDriver"]),

        // CLI tool
        .executable(name: "mobile-test", targets: ["CLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // ── Core Interface ──────────────────────────
        .target(
            name: "AmooCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // ── Platform Drivers ────────────────────────
        .target(
            name: "IOSDriver",
            dependencies: ["AmooCore"]
        ),
        .target(
            name: "AndroidDriver",
            dependencies: ["AmooCore"]
        ),

        // ── gRPC Service Layer ──────────────────────
        .target(
            name: "GRPCService",
            dependencies: [
                "AmooCore",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf"),
            ]
        ),

        // ── CLI ─────────────────────────────────────
        .executableTarget(
            name: "CLI",
            dependencies: [
                "AmooCore",
                "IOSDriver",
                "AndroidDriver",
                "GRPCService",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // ── Tests ───────────────────────────────────
        .testTarget(
            name: "AmooCoreTests",
            dependencies: ["AmooCore"]
        ),
        .testTarget(
            name: "IOSDriverTests",
            dependencies: ["IOSDriver", "AmooCore"]
        ),
        .testTarget(
            name: "AndroidDriverTests",
            dependencies: ["AndroidDriver", "AmooCore"]
        ),
    ]
)
```

### Directory structure

```
AmooFramework/
├── Package.swift
├── Sources/
│   ├── AmooCore/         # Protocols + shared types
│   │   ├── DeviceDriver.swift
│   │   ├── DeviceInfo.swift
│   │   ├── Actions.swift
│   │   └── Errors.swift
│   ├── IOSDriver/                 # iOS implementation
│   │   ├── IOSDeviceDriver.swift
│   │   ├── SimctlRunner.swift
│   │   └── IOSAccessibility.swift
│   ├── AndroidDriver/             # Android implementation
│   │   ├── AndroidDeviceDriver.swift
│   │   ├── ADBRunner.swift
│   │   └── UIAutomatorParser.swift
│   ├── GRPCService/               # gRPC layer
│   │   ├── Protos/
│   │   │   └── device_driver.proto
│   │   └── DeviceDriverService.swift
│   └── CLI/                       # Command-line tool
│       ├── CLI.swift
│       └── Commands/
│           ├── RunCommand.swift
│           ├── ListCommand.swift
│           └── AuditCommand.swift
└── Tests/
    ├── AmooCoreTests/
    │   └── MockDriverTests.swift
    ├── IOSDriverTests/
    │   └── IOSDriverTests.swift
    └── AndroidDriverTests/
        └── AndroidDriverTests.swift
```

## Protocol-Oriented Design

### Core interface pattern

```swift
// Sources/AmooCore/DeviceDriver.swift

/// Platform-agnostic interface for device interaction.
/// iOS and Android drivers conform to this protocol.
public protocol DeviceDriver: Sendable {
    var deviceInfo: DeviceInfo { get async throws }

    // Lifecycle
    func boot() async throws
    func shutdown() async throws

    // App management
    func installApp(at path: String) async throws
    func launchApp(bundleId: String) async throws
    func terminateApp(bundleId: String) async throws

    // Actions
    func tap(x: Int, y: Int) async throws
    func swipe(from: Point, to: Point, duration: Duration) async throws
    func typeText(_ text: String) async throws

    // Capture
    func takeScreenshot() async throws -> ScreenshotData
    func startRecording() async throws -> RecordingSession
    func getAccessibilityTree() async throws -> AccessibilityNode
}
```

```swift
// Sources/AmooCore/DeviceInfo.swift

public struct DeviceInfo: Sendable {
    public let id: String
    public let name: String
    public let platform: Platform
    public let osVersion: String
    public let screenSize: Size
    public let state: DeviceState

    public init(id: String, name: String, platform: Platform,
                osVersion: String, screenSize: Size, state: DeviceState) {
        self.id = id
        self.name = name
        self.platform = platform
        self.osVersion = osVersion
        self.screenSize = screenSize
        self.state = state
    }
}

public enum Platform: String, Sendable {
    case ios
    case android
}

public enum DeviceState: String, Sendable {
    case booted
    case shutdown
    case unknown
}

public struct Point: Sendable {
    public let x: Int
    public let y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct Size: Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}
```

### Error design

```swift
// Sources/AmooCore/Errors.swift

public enum DriverError: Error, Sendable {
    case deviceNotFound(String)
    case deviceNotBooted(String)
    case appNotInstalled(bundleId: String)
    case commandFailed(command: String, output: String, exitCode: Int32)
    case timeout(operation: String, duration: Duration)
    case unsupportedOperation(String)
}
```

### Platform implementation

```swift
// Sources/IOSDriver/IOSDeviceDriver.swift

import AmooCore
import Foundation

public struct IOSDeviceDriver: DeviceDriver {
    private let udid: String
    private let runner: SimctlRunner

    public init(udid: String) {
        self.udid = udid
        self.runner = SimctlRunner()
    }

    public var deviceInfo: DeviceInfo {
        get async throws {
            let json = try await runner.exec("list", "devices", "-j")
            // Parse JSON and find device by UDID
            return try parseDeviceInfo(json, udid: udid)
        }
    }

    public func tap(x: Int, y: Int) async throws {
        // iOS requires XCUITest or accessibility APIs for tap
        // simctl doesn't have direct input commands
        throw DriverError.unsupportedOperation(
            "Direct tap requires XCUITest bridge — use accessibility-based interaction"
        )
    }

    public func takeScreenshot() async throws -> ScreenshotData {
        let data = try await runner.exec("io", udid, "screenshot", "--type=png", "-")
        return ScreenshotData(data: data, format: .png)
    }
    // ... other implementations
}
```

## Dependency Management

### Version specifications

```swift
dependencies: [
    // Minimum version (most common)
    .package(url: "https://github.com/example/lib.git", from: "1.0.0"),

    // Exact version
    .package(url: "https://github.com/example/lib.git", exact: "1.2.3"),

    // Version range
    .package(url: "https://github.com/example/lib.git", "1.0.0"..<"2.0.0"),

    // Branch (for development only)
    .package(url: "https://github.com/example/lib.git", branch: "main"),

    // Revision (specific commit)
    .package(url: "https://github.com/example/lib.git", revision: "abc123"),

    // Local package (for development)
    .package(path: "../my-local-package"),
]
```

### Conditional dependencies

```swift
targets: [
    .target(
        name: "IOSDriver",
        dependencies: [
            "AmooCore",
            // Platform-conditional dependency
            .target(name: "IOSBridge", condition: .when(platforms: [.macOS, .iOS])),
        ]
    ),
]
```

### Product types

```swift
products: [
    // Library (static by default)
    .library(name: "MyLib", targets: ["MyLib"]),

    // Dynamic library
    .library(name: "MyLib", type: .dynamic, targets: ["MyLib"]),

    // Static library (explicit)
    .library(name: "MyLib", type: .static, targets: ["MyLib"]),

    // Executable
    .executable(name: "my-tool", targets: ["CLI"]),

    // Plugin
    .plugin(name: "MyPlugin", targets: ["MyPlugin"]),
]
```

## Target Types

```swift
targets: [
    // Regular library target
    .target(name: "MyLib"),

    // Executable
    .executableTarget(name: "MyTool"),

    // Test target
    .testTarget(name: "MyLibTests", dependencies: ["MyLib"]),

    // Build tool plugin (runs during build)
    .plugin(
        name: "MyBuildPlugin",
        capability: .buildTool()
    ),

    // Command plugin (runs on demand)
    .plugin(
        name: "MyCommandPlugin",
        capability: .command(
            intent: .custom(verb: "my-command", description: "Does something"),
            permissions: [.writeToPackageDirectory(reason: "Generates code")]
        )
    ),

    // Macro
    .macro(
        name: "MyMacro",
        dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        ]
    ),

    // System library (wraps C library)
    .systemLibrary(
        name: "CMyLib",
        pkgConfig: "mylib",
        providers: [.brew(["mylib"]), .apt(["libmylib-dev"])]
    ),

    // Binary target
    .binaryTarget(
        name: "MyBinary",
        url: "https://example.com/MyBinary.xcframework.zip",
        checksum: "abc123..."
    ),
]
```

## Build Settings

```swift
.target(
    name: "MyTarget",
    dependencies: [],
    swiftSettings: [
        // Swift language version
        .swiftLanguageMode(.v6),

        // Upcoming features
        .enableUpcomingFeature("ExistentialAny"),
        .enableExperimentalFeature("StrictConcurrency"),

        // Defines
        .define("DEBUG", .when(configuration: .debug)),
        .define("ENABLE_LOGGING"),

        // Unsafe flags (avoid if possible)
        .unsafeFlags(["-Xfrontend", "-warn-long-expression-type-checking=100"]),
    ],
    linkerSettings: [
        .linkedLibrary("sqlite3"),
        .linkedFramework("UIKit", .when(platforms: [.iOS])),
    ]
)
```

## Testing Patterns

### Mockable protocol design

```swift
// The protocol in AmooCore enables mocking:
public protocol DeviceDriver: Sendable { /* ... */ }

// Test mock in test target:
struct MockDeviceDriver: DeviceDriver {
    var tapCalls: [(x: Int, y: Int)] = []
    var screenshotToReturn: ScreenshotData?

    mutating func tap(x: Int, y: Int) async throws {
        tapCalls.append((x, y))
    }

    func takeScreenshot() async throws -> ScreenshotData {
        guard let screenshot = screenshotToReturn else {
            throw DriverError.commandFailed(command: "screenshot", output: "not configured", exitCode: 1)
        }
        return screenshot
    }
    // ... other mock implementations
}
```

### Swift Testing (@Test)

```swift
import Testing
@testable import AmooCore

@Test("Device info parses correctly")
func deviceInfoParsing() throws {
    let info = DeviceInfo(
        id: "ABC-123",
        name: "iPhone 16",
        platform: .ios,
        osVersion: "18.0",
        screenSize: Size(width: 1170, height: 2532),
        state: .booted
    )
    #expect(info.platform == .ios)
    #expect(info.state == .booted)
}

@Test("Tap records coordinates", arguments: [
    (x: 100, y: 200),
    (x: 500, y: 1200),
])
func tapCoordinates(x: Int, y: Int) async throws {
    var mock = MockDeviceDriver()
    try await mock.tap(x: x, y: y)
    #expect(mock.tapCalls.count == 1)
    #expect(mock.tapCalls[0].x == x)
}
```

### Running tests

```bash
# Run all tests
swift test

# Run specific test target
swift test --filter AmooCoreTests

# Run specific test
swift test --filter "AmooCoreTests.deviceInfoParsing"

# Parallel testing
swift test --parallel

# With code coverage
swift test --enable-code-coverage

# Verbose output
swift test -v
```

## Access Control for Module Boundaries

Key principle: **Public protocols in core, internal implementations in drivers.**

```swift
// AmooCore — everything consumers need is public
public protocol DeviceDriver { ... }
public struct DeviceInfo { ... }
public enum DriverError: Error { ... }

// IOSDriver — public factory, internal implementation details
public struct IOSDeviceDriver: DeviceDriver { ... }  // public: consumers create these
internal struct SimctlRunner { ... }                  // internal: implementation detail
private func parseJSON(_ data: Data) { ... }          // private: helper
```

## Traits (Swift 6.0+)

Package traits allow conditional compilation based on feature flags:

```swift
let package = Package(
    name: "MyPackage",
    traits: [
        .trait(name: "Logging", description: "Enable detailed logging"),
        .trait(name: "Metrics", description: "Enable metrics collection"),
        .default(enabledTraits: ["Logging"]),  // enabled by default
    ],
    targets: [
        .target(
            name: "MyLib",
            swiftSettings: [
                .define("LOGGING_ENABLED", .when(traits: ["Logging"])),
            ]
        ),
    ]
)
```

```bash
# Build with specific traits
swift build --traits Logging,Metrics

# Build with all traits
swift build --enable-all-traits

# Build without defaults
swift build --disable-default-traits
```

## Common Patterns

### Process runner (for CLI tool wrappers)

```swift
// Shared utility for running external commands (simctl, adb, etc.)
public struct ProcessRunner: Sendable {
    private let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    public func run(_ arguments: String...) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(filePath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }
}
```

### Factory pattern for driver selection

```swift
public struct DriverFactory {
    public static func createDriver(
        platform: Platform,
        deviceId: String
    ) -> any DeviceDriver {
        switch platform {
        case .ios:
            return IOSDeviceDriver(udid: deviceId)
        case .android:
            return AndroidDeviceDriver(serial: deviceId)
        }
    }
}
```
