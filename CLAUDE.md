# mobile-testing

AI-driven mobile testing framework providing drivers and libraries for automating tests on iOS and Android simulators/emulators and real devices.

## Project Status

Greenfield project — no code yet. See `Instruction.md` for the full vision.

## Tech Stack

- **Primary language**: Swift (other languages where appropriate)
- **Communication**: gRPC (language-agnostic, high-performance)
- **AI integration**: MCP + Skills (hybrid approach), Ollama for local LLMs
- **Platforms**: iOS (simulators + devices), Android (emulators + devices)

## Architecture

- **Interface libs**: Shared protocol/interface definitions for cross-platform feature parity
- **Platform implementations**: iOS-specific and Android-specific drivers implementing the shared interfaces
- **Modular design**: Easy to extend with new platforms, actions, and AI integrations
- **gRPC services**: Bridge between drivers/libraries and AI tools

### Key Modules (Planned)

- Device drivers (scroll, tap, type, screenshot, video recording)
- App audit engine (issues, security, UX, test reliability)
- AI test generation
- CLI + REPL interface
- CI/CD integration

## Design Principles

- AI as first-class citizen in the testing process
- Feature parity between iOS and Android
- Mockable and testable — design for easy mocking and unit testing
- User-friendly errors with setup hints
- Apps identified by app ID or app name

## Build & Test

```bash
# TODO: Fill in as code is written
# swift build
# swift test
```

## Conventions

- Follow Swift modern APIs (`async/await`, `@Observable`, Swift Testing)
- gRPC proto files define the shared interface contract
- Keep platform-specific code isolated behind shared protocols
- Document public APIs
- Log operations using structured logging (see global CLAUDE.md for Logger patterns)
