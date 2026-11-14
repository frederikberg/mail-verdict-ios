import MailVerdictKit
import SwiftUI

/// Backend address and sign-in.
///
/// Signing in goes through the server's own Zitadel login in a system browser sheet and leaves a
/// token set the app renews by itself, so a person signs in once and stays signed in until they
/// sign out or the server revokes the device.
///
/// One screen serves two situations, because the fields are the same and only the explanation
/// differs. They are kept as distinct cases rather than one flag, so a refused sign-in can say
/// what happened instead of pretending nothing has been set up yet.
struct SignInView: View {

    enum Reason {
        case firstLaunch
        /// The stored sign-in was refused; the detail is whatever the backend said, if anything.
        case rejected(String?)
    }

    let environment: AppEnvironment
    let reason: Reason

    @State private var url: String = ""
    @State private var failed = false
    @State private var coordinator = OidcSignInCoordinator()
    @State private var signingIn = false
    @State private var signInMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if case .rejected(let detail) = reason {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                if detail == MVError.deviceRevokedMessage {
                                    Text(MVError.deviceRevokedMessage)
                                } else {
                                    Text("You were signed out.")
                                    if let detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("Backend") {
                    TextField("https://…", text: $url)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("signin-url")
                }

                Section {
                    Button {
                        Task { await signInWithServer() }
                    } label: {
                        HStack {
                            Text("Sign in with Zitadel")
                            if signingIn {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(url.isEmpty || signingIn)
                    .accessibilityIdentifier("signin-oidc")
                    if let signInMessage {
                        Text(signInMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("signin-oidc-message")
                    }
                    if urlIsCleartext {
                        Label {
                            Text("This address is http, not https — what you sign in with will travel in the clear.")
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("Opens your server's sign-in page. You stay signed in on this iPhone until you sign out.")
                }

                if failed {
                    Text("That backend address could not be used. It needs a scheme, http or https.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(title)
        }
        .onAppear {
            // Prefilled rather than blank: on a rejection the address is definitely right and
            // only the sign-in needs repeating. On first launch there is nothing to prefill.
            if url.isEmpty { url = environment.backendURL }
        }
    }

    private var urlIsCleartext: Bool {
        url.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    private var title: String {
        switch reason {
        case .firstLaunch: "Sign in"
        case .rejected: "Sign in again"
        }
    }

    /// The server's own sign-in.
    private func signInWithServer() async {
        signingIn = true
        signInMessage = nil
        defer { signingIn = false }
        do {
            switch try await coordinator.signIn(backendURL: url) {
            case .signedIn(let tokens):
                failed = !environment.signIn(backendURL: url, tokens: tokens)
            case .cancelled:
                break
            }
        } catch let failure as OidcSignInCoordinator.Failure {
            signInMessage = failure.message
        } catch {
            signInMessage = error.mvUserMessage
        }
    }
}
