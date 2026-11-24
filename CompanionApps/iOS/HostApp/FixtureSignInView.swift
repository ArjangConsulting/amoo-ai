import SwiftUI

/// A sign-in form with a password field whose submit button brings up a SwiftUI `.alert`.
///
/// It reproduces two things a real app's sign-in does to a driver: typing into a secure field, and
/// tapping a button on an alert that may still be animating in, where the system can drop the tap.
/// The alert's buttons change `fixture-sign-in-status`, so a test can tell a tap that landed from one
/// that was dropped.
struct FixtureSignInView: View {
    @State private var username = ""
    @State private var password = ""
    @State private var alertShown = false
    @State private var status = "Signed out"

    var body: some View {
        Form {
            Section("Account") {
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .accessibilityIdentifier("fixture-sign-in-username")

                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("fixture-sign-in-password")

                Text("Password length: \(password.count)")
                    .accessibilityIdentifier("fixture-sign-in-password-length")
            }

            Section {
                Button("Sign In") {
                    alertShown = true
                }
                .disabled(username.isEmpty || password.isEmpty)
                .accessibilityIdentifier("fixture-sign-in-submit")

                Text(status)
                    .accessibilityIdentifier("fixture-sign-in-status")
            }
        }
        .navigationTitle("Sign In")
        .alert("Signed in as \(username)", isPresented: $alertShown) {
            Button("Continue") {
                status = "Signed in"
            }
            .accessibilityIdentifier("fixture-sign-in-alert-continue")
            Button("Cancel", role: .cancel) {
                status = "Sign-in cancelled"
            }
            .accessibilityIdentifier("fixture-sign-in-alert-cancel")
        } message: {
            Text("Continue to the account, or cancel to stay signed out.")
        }
    }
}
