import SwiftUI
import UIKit

/// Explicit seeds qualify authored checks against known concerns and an otherwise identical clean control.
struct FixtureAccessibilityView: View {
    let seed: String
    @State private var page = 1
    @State private var dialogOpen = false
    @AccessibilityFocusState(for: .voiceOver) private var focus: Focus?

    private enum Focus: Hashable { case first, next, dialog, open }

    var body: some View {
        VStack(spacing: 18) {
            Text("Fixture seed: \(seed)")
                .accessibilityIdentifier("a11y-seed")
            Text("First journey item")
                .accessibilityIdentifier("a11y-first")
                .accessibilitySortPriority(seed == "order" ? 1 : 2)
                .accessibilityFocused($focus, equals: .first)
            Text("Second journey item")
                .accessibilityIdentifier("a11y-second")
                .accessibilitySortPriority(seed == "order" ? 2 : 1)
            JourneyPageLabel(page: page, requestsFocus: seed != "focus")
                .fixedSize(horizontal: false, vertical: true)
            if seed == "role" {
                Text("Selected option")
                    .accessibilityIdentifier("a11y-option")
                    .accessibilityAddTraits(.isSelected)
            } else {
                Button("Selected option") {}
                    .accessibilityIdentifier("a11y-option")
                    .accessibilityAddTraits(seed == "state" ? [] : .isSelected)
                    .accessibilityLabel(seed == "name" ? "Unrelated action" : "Selected option")
            }
            Button("Next page") {
                page += 1
            }
            .accessibilityIdentifier("a11y-next")
            .accessibilityFocused($focus, equals: .next)
            Button("Open dialog") { dialogOpen = true }
                .accessibilityIdentifier("a11y-open-dialog")
                .accessibilityFocused($focus, equals: .open)
            Text(dialogOpen ? "Dialog open" : "Dialog closed")
                .accessibilityIdentifier("a11y-dialog-state")
        }
        .padding()
        .navigationTitle("Accessibility Journey")
        .sheet(isPresented: $dialogOpen, onDismiss: {
            focus = seed == "dismissal" ? .first : .open
        }) {
            VStack(spacing: 20) {
                Text("Journey dialog")
                    .accessibilityIdentifier("a11y-dialog-title")
                    .accessibilityFocused($focus, equals: .dialog)
                Button("Dismiss dialog") { dialogOpen = false }
                    .accessibilityIdentifier("a11y-dismiss-dialog")
            }
            .padding()
            .onAppear { focus = .dialog }
        }
    }
}

/// The clean control requests focus on a real element after updating its layout, never an announcement string.
private struct JourneyPageLabel: UIViewRepresentable {
    let page: Int
    let requestsFocus: Bool

    func makeUIView(context _: Context) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.numberOfLines = 0
        label.isAccessibilityElement = true
        label.accessibilityIdentifier = "a11y-page"
        return label
    }

    func updateUIView(_ label: UILabel, context _: Context) {
        let text = "Page \(page)"
        let changed = label.text != nil && label.text != text
        label.text = text
        label.accessibilityLabel = text
        guard changed, requestsFocus else { return }
        // Let VoiceOver finish activation before the app requests the next page's focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak label] in
            guard let label, label.window != nil, label.text == text else { return }
            label.layoutIfNeeded()
            UIAccessibility.post(notification: .layoutChanged, argument: label)
        }
    }
}
