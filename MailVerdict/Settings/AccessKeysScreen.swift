import MailVerdictKit
import SwiftUI

/// Settings > Access Keys: the agents, scripts and other clients that sign in as you, what each
/// may do, and signing one out. A port of the access key half of the web's Signed-in devices
/// screen; attaching a key and changing what it may do stay on the web.
struct AccessKeysScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: MVAccessKeysStore
    @State private var signingOut: AccessKeyResponse?

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        _store = State(initialValue: MVAccessKeysStore(apiClient: connection.apiClient))
    }

    var body: some View {
        content
            .navigationTitle("Access Keys")
            .accessibilityIdentifier("access-keys-screen")
            #if DEBUG
                .screenshotReady(route: .accessKeys, environment: environment, connection: connection)
            #endif
            .task { await store.load() }
            .refreshable { await store.load() }
            .onAppear { store.subscribeToLive(connection.liveEventHub) }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
            .confirmationDialog(
                "Sign out \(signingOut?.displayName ?? "")?",
                isPresented: Binding(get: { signingOut != nil }, set: { if !$0 { signingOut = nil } }),
                titleVisibility: .visible,
                presenting: signingOut
            ) { key in
                Button("Sign Out", role: .destructive) { Task { await signOut(key) } }
            } message: { _ in
                Text(mvAccessKeySignOutConsequence)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .loading:
            ProgressView()
        case .failed(let error):
            ErrorStateView(error: error) { Task { await store.load() } }
        case .loaded:
            List {
                Section {
                    if store.keys.isEmpty {
                        Text("No access key acts as you.").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.keys) { key in
                            AccessKeyRow(key: key, calendarNames: store.calendarNames) {
                                signingOut = key
                            }
                        }
                    }
                } footer: {
                    Text("Agents, scripts and other clients that act as you. What a key may do is changed on the web.")
                }
            }
        }
    }

    private func signOut(_ key: AccessKeyResponse) async {
        signingOut = nil
        do {
            try await store.signOut(key)
        } catch {
            environment.toasts.show(
                .init(variant: .error, message: "Could not sign it out: \(error.mvUserMessage)"))
        }
    }
}

private struct AccessKeyRow: View {
    let key: AccessKeyResponse
    let calendarNames: [UUID: String]
    let onSignOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.displayName)
                    .strikethrough(key.state == .signedOut)
                    .foregroundStyle(key.state == .signedOut ? .secondary : .primary)
                Spacer()
                if key.access == .full {
                    Label("Full access", systemImage: "exclamationmark.shield.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Text("Limited").font(.caption).foregroundStyle(.secondary)
                }
            }
            if key.access == .full {
                Text("Everything you may do, mail and settings included.")
                    .font(.caption).foregroundStyle(.red)
            } else {
                let lines = key.grantLines(calendarNames: calendarNames)
                ForEach(lines.isEmpty ? ["Nothing: it can do nothing but ask who it is."] : lines, id: \.self) {
                    Text($0).font(.caption)
                }
                Text(mvScopedKeyExcludes).font(.caption).foregroundStyle(.secondary)
            }
            Text(key.activityLine()).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .swipeActions {
            if key.canSignOut {
                Button("Sign Out", role: .destructive, action: onSignOut)
            }
        }
        .contextMenu {
            if key.canSignOut {
                Button("Sign Out", role: .destructive, action: onSignOut)
            }
        }
        .accessibilityIdentifier("access-key-\(key.subject)")
    }
}
