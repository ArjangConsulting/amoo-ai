import SwiftUI

/// Host for the macOS companion's UI-test bundle. XCTest needs a target application for a macOS
/// UI-test bundle, but the companion drives other apps and never launches this one.
@main
struct CompanionMacHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("amoo companion host")
                .padding()
        }
    }
}
