import MailVerdictKit
import SwiftUI

/// Settings — appearance, mail-wide preferences, server configuration, accounts, and the
/// connection itself. Every row pushes its own screen; nothing here has a Save button, since each
/// one commits its own change immediately.
struct SettingsScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var accountOrderStore: MVAccountOrderStore?

    /// The server-wide categories this user may open, in the order the screen lists them; none for
    /// an ordinary user, and none until the server has said who is signed in.
    private var adminCategories: [MVSettingsCategory] {
        [.orders, .ai, .assistant, .semantic, .retry, .pipeline].filter { connection.me.canOpen($0) }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                ThemePicker(environment: environment)
            }

            Section("Mail") {
                if let accountOrderStore, accountOrderStore.accounts.count >= 2 {
                    NavigationLink("Account Order", value: Route.accountOrder)
                }
                NavigationLink("Unified Views", value: Route.unifiedViews)
                NavigationLink("New Mail Notifications", value: Route.notificationSettings)
                NavigationLink(
                    "Filing and Notifications", value: Route.settingsCategory(MVSettingsCategory.mail.rawValue))
            }

            Section("Sending") {
                NavigationLink("Outbox", value: Route.settingsCategory(MVSettingsCategory.outbox.rawValue))
            }

            if !adminCategories.isEmpty {
                Section("Advanced") {
                    ForEach(adminCategories, id: \.rawValue) { category in
                        NavigationLink(category.displayTitle, value: Route.settingsCategory(category.rawValue))
                    }
                }
            }

            Section("Accounts") {
                NavigationLink("Accounts", value: Route.accounts)
            }

            Section("Connection") {
                LabeledContent("Server", value: environment.backendURL)
                if let me = connection.me.me {
                    LabeledContent("Signed in as", value: me.displayName)
                    if let email = me.email {
                        LabeledContent("Email", value: email)
                    }
                    LabeledContent("Role", value: me.isAdmin ? "Administrator" : "User")
                }
                Button("Sign Out", role: .destructive) {
                    environment.signOut()
                }
            }
        }
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings-screen")
        #if DEBUG
            .screenshotReady(route: .settings, environment: environment, connection: connection)
        #endif
        .task {
            let store = accountOrderStore ?? MVAccountOrderStore(apiClient: connection.apiClient)
            accountOrderStore = store
            #if DEBUG
                SettingsDebugServices.shared.activeAccountOrderStore = store
            #endif
            await store.load()
        }
    }
}

/// System / Light / Dark — device-local, applied to the whole window.
private struct ThemePicker: View {
    let environment: AppEnvironment

    private enum Choice: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }
    }

    private var choice: Choice {
        switch environment.colorScheme {
        case .light: return .light
        case .dark: return .dark
        default: return .system
        }
    }

    var body: some View {
        Picker("Theme", selection: Binding(get: { choice }, set: { apply($0) })) {
            ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
        }
    }

    private func apply(_ choice: Choice) {
        switch choice {
        case .system: environment.colorScheme = nil
        case .light: environment.colorScheme = .light
        case .dark: environment.colorScheme = .dark
        }
    }
}
