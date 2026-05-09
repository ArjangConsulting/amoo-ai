import SwiftUI

private enum FixtureRoute: Hashable {
    case details
    case textInput
    case gesture
    case permissions
    case appearance
    case deepLink
    case confirmation
}

@main
struct CompanionHostApp: App {
    @State private var path: [FixtureRoute] = []
    @State private var textValue = "Hello from the fixture app"
    @State private var tapCount = 0
    @State private var doubleTapCount = 0
    @State private var longPressState = "idle"
    @State private var deepLinkValue = "No URL opened yet"

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                FixtureHomeView(
                    tapCount: $tapCount,
                    doubleTapCount: $doubleTapCount,
                    longPressState: $longPressState
                )
                .navigationDestination(for: FixtureRoute.self) { route in
                    switch route {
                    case .details:
                        FixtureDetailsView()
                    case .textInput:
                        FixtureTextInputView(textValue: $textValue)
                    case .gesture:
                        FixtureGestureView(
                            tapCount: $tapCount,
                            doubleTapCount: $doubleTapCount,
                            longPressState: $longPressState
                        )
                    case .permissions:
                        FixturePermissionsView()
                    case .appearance:
                        FixtureAppearanceView()
                    case .deepLink:
                        FixtureDeepLinkView(deepLinkValue: $deepLinkValue)
                    case .confirmation:
                        FixtureConfirmationView()
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button("Details") { path = [.details] }
                            .accessibilityIdentifier("fixture-open-details")
                        Button("Text") { path = [.textInput] }
                            .accessibilityIdentifier("fixture-open-text")
                        Button("Gesture") { path = [.gesture] }
                            .accessibilityIdentifier("fixture-open-gesture")
                    }
                }
            }
            .onOpenURL { url in
                handle(url: url)
            }
        }
    }

    private func handle(url: URL) {
        guard url.scheme == "mobile-testing" else { return }

        switch url.host {
        case "details":
            path = [.details]
        case "text":
            path = [.textInput]
        case "gesture":
            path = [.gesture]
        case "permissions":
            path = [.permissions]
        case "appearance":
            path = [.appearance]
        case "confirm":
            path = [.confirmation]
        default:
            deepLinkValue = url.absoluteString
            path = [.deepLink]
        }
    }
}

private struct FixtureHomeView: View {
    @Binding var tapCount: Int
    @Binding var doubleTapCount: Int
    @Binding var longPressState: String

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Fixture Home")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("fixture-home-title")

                    Text("Home screen ready for contract tests")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("fixture-home-screen")
                }
            }

            Section("Launch Targets") {
                NavigationLink("Open Details", value: FixtureRoute.details)
                    .accessibilityIdentifier("fixture-open-details")
                NavigationLink("Open Text Input", value: FixtureRoute.textInput)
                    .accessibilityIdentifier("fixture-open-text")
                NavigationLink("Open Gesture Lab", value: FixtureRoute.gesture)
                    .accessibilityIdentifier("fixture-open-gesture")
                NavigationLink("Open Permissions", value: FixtureRoute.permissions)
                    .accessibilityIdentifier("fixture-open-permissions")
                NavigationLink("Open Appearance", value: FixtureRoute.appearance)
                    .accessibilityIdentifier("fixture-open-appearance")
                NavigationLink("Open Deep Link", value: FixtureRoute.deepLink)
                    .accessibilityIdentifier("fixture-open-deeplink")
                NavigationLink("Open Confirmation", value: FixtureRoute.confirmation)
                    .accessibilityIdentifier("fixture-open-confirmation")
            }

            Section("Gesture Summary") {
                Text("Tap count: \(tapCount)")
                    .accessibilityIdentifier("fixture-tap-count")
                Text("Double tap count: \(doubleTapCount)")
                    .accessibilityIdentifier("fixture-double-tap-count")
                Text("Long press: \(longPressState)")
                    .accessibilityIdentifier("fixture-long-press-status")
            }
        }
        .navigationTitle("Fixture")
    }
}

private struct FixtureDetailsView: View {
    var body: some View {
        List(0 ..< 30, id: \.self) { index in
            Text("Fixture row \(index)")
                .accessibilityIdentifier("fixture-detail-row-\(index)")
        }
        .overlay(alignment: .bottom) {
            Text("Details tail marker")
                .font(.footnote.bold())
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: Capsule())
                .accessibilityIdentifier("fixture-details-tail")
                .padding()
        }
        .navigationTitle("Details")
    }
}

private struct FixtureTextInputView: View {
    @Binding var textValue: String

    var body: some View {
        Form {
            Section("Input") {
                TextField("Fixture Input", text: $textValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("fixture-text-input")

                Text(textValue)
                    .accessibilityIdentifier("fixture-text-value")
            }
        }
        .navigationTitle("Text Input")
    }
}

private struct FixtureGestureView: View {
    @Binding var tapCount: Int
    @Binding var doubleTapCount: Int
    @Binding var longPressState: String

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Gesture Pad")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .background(Color.orange.gradient, in: RoundedRectangle(cornerRadius: 24))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tapCount += 1
                    }
                    .onTapGesture(count: 2) {
                        doubleTapCount += 1
                    }
                    .onLongPressGesture {
                        longPressState = "completed"
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Gesture Pad")
                    .accessibilityIdentifier("fixture-gesture-pad")

                Text("Scroll target")
                    .font(.headline)
                    .accessibilityIdentifier("fixture-gesture-scroll-target")

                ForEach(0 ..< 10, id: \.self) { index in
                    Text("Gesture item \(index)")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("fixture-gesture-item-\(index)")
                }
            }
            .padding()
        }
        .navigationTitle("Gesture Lab")
    }
}

private struct FixturePermissionsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Permissions Screen")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture-permissions-screen")
            Text("Use host commands to grant camera, notifications, or location.")
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Permissions")
    }
}

private struct FixtureAppearanceView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 12) {
            Text("Appearance Screen")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture-appearance-screen")
            Text(colorScheme == .dark ? "dark" : "light")
                .accessibilityIdentifier("fixture-appearance-value")
        }
        .padding()
        .navigationTitle("Appearance")
    }
}

private struct FixtureDeepLinkView: View {
    @Binding var deepLinkValue: String

    var body: some View {
        VStack(spacing: 12) {
            Text("Deep Link Screen")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture-deeplink-screen")
            Text(deepLinkValue)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("fixture-deeplink-value")
        }
        .padding()
        .navigationTitle("Deep Link")
    }
}

private struct FixtureConfirmationView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Confirmation Screen")
                .font(.title2.bold())
                .accessibilityIdentifier("fixture-confirmation-screen")
            Text("The fixture app reached its confirmation state.")
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("fixture-confirmation-message")
        }
        .padding()
        .navigationTitle("Confirmation")
    }
}
