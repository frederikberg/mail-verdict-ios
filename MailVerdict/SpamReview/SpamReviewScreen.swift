import MailVerdictKit
import SwiftUI

/// The verdict queue — every message the classifier currently calls spam with no ruling yet,
/// Not Spam / Spam buttons, swipes and All Good / All Spam.
struct SpamReviewScreen: View {
    let environment: AppEnvironment
    let connection: AppEnvironment.Connection

    @State private var store: SpamReviewStore
    @State private var accounts: [AccountResponse] = []
    @State private var pendingBulk: PendingBulk?
    @State private var isDeciding = false

    private enum PendingBulk: Identifiable {
        case notSpam
        case spam
        var id: Self { self }
    }

    init(environment: AppEnvironment, connection: AppEnvironment.Connection) {
        self.environment = environment
        self.connection = connection
        self._store = State(initialValue: SpamReviewStore(apiClient: connection.apiClient))
    }

    var body: some View {
        content
            .navigationTitle("Spam Review")
            .navigationSubtitle("\(store.items.count) to review")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            pendingBulk = .notSpam
                        } label: {
                            Label("All Good", mvSymbol: MVSymbols.notSpam)
                        }
                        .disabled(store.items.isEmpty || store.isBulkRunning)
                        Button {
                            pendingBulk = .spam
                        } label: {
                            Label("All Spam", mvSymbol: MVSymbols.spam)
                        }
                        .disabled(store.items.isEmpty || store.isBulkRunning)
                    } label: {
                        Image(systemName: MVSymbols.options)
                    }
                }
            }
            .alert(item: $pendingBulk) { bulk in
                switch bulk {
                case .spam:
                    Alert(
                        title: Text("Mark \(store.items.count) messages as spam?"),
                        message: Text("Rules every message currently listed spam and moves it to Junk."),
                        primaryButton: .default(Text("All Spam")) { Task { await runBulk(isSpam: true) } },
                        secondaryButton: .cancel()
                    )
                case .notSpam:
                    Alert(
                        title: Text("Mark \(store.items.count) messages as not spam?"),
                        message: Text(
                            "Rules every message currently listed not spam, and moves any of them sitting in Junk back to the inbox."
                        ),
                        primaryButton: .default(Text("All Good")) { Task { await runBulk(isSpam: false) } },
                        secondaryButton: .cancel()
                    )
                }
            }
            .task {
                #if DEBUG
                    SpamReviewFixtures.activeStore = store
                #endif
                store.subscribeToLive(connection.liveEventHub)
                ReaderSourceRegistry.shared.register(store, for: .spamReview)
                accounts = (try? await connection.apiClient.listAccounts()) ?? []
                await store.load()
            }
            .onDisappear { store.unsubscribeFromLive(connection.liveEventHub) }
            #if DEBUG
                .screenshotReady(route: .spamReview, environment: environment, connection: connection)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView()
        } else if let errorMessage = store.errorMessage {
            ErrorStateView(message: errorMessage) { Task { await store.load() } }
        } else if store.items.isEmpty {
            EmptyStateView(systemImage: MVSymbols.nothingToReview, message: "Nothing to review")
        } else {
            List {
                ForEach(store.items) { item in
                    row(for: item)
                }
                if store.hasOlder {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await store.loadOlder() }
                }
            }
        }
    }

    /// Not a `Button` wrapping the whole row: Not Spam and Spam need their own independent tap
    /// targets, which a `Button` nested inside another `Button`'s label cannot reliably give —
    /// `onTapGesture` on the row's own content shape opens the reader instead, and a button's tap
    /// is consumed by its own `Button` before it ever reaches that gesture.
    private func row(for item: SpamReviewItem) -> some View {
        SpamReviewRow(
            item: item, accountChip: accounts.count > 1 ? accountName(for: item.accountId) : nil,
            onNotSpam: { Task { await decide(item, isSpam: false) } },
            onSpam: { Task { await decide(item, isSpam: true) } }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            environment.navigationPath.append(.reader(ReaderContext(source: .spamReview, messageId: item.messageId)))
        }
        .disabled(isDeciding)
        .swipeActions(edge: .leading) {
            Button("Not Spam") { Task { await decide(item, isSpam: false) } }.tint(.green)
        }
        .swipeActions(edge: .trailing) {
            Button("Spam") { Task { await decide(item, isSpam: true) } }.tint(.red)
        }
    }

    private func accountName(for accountId: UUID) -> String? {
        accounts.first { $0.id == accountId }?.name
    }

    private func decide(_ item: SpamReviewItem, isSpam: Bool) async {
        isDeciding = true
        try? await store.decide(item, isSpam: isSpam)
        isDeciding = false
    }

    private func runBulk(isSpam: Bool) async {
        let result = await store.decideAll(isSpam: isSpam)
        let toast: MVToast
        if result.failed > 0 {
            toast = MVToast(
                variant: .error,
                message:
                    "\(result.failed) of \(result.attempted) could not be marked as \(isSpam ? "spam" : "not spam")",
                duration: 0
            )
        } else {
            toast = MVToast(
                variant: .success,
                message: "\(result.succeeded) message\(result.succeeded == 1 ? "" : "s") "
                    + (isSpam ? "marked as spam" : "marked as not spam")
            )
        }
        environment.toasts.show(toast)
    }
}

/// One review row — sender, Junk/account chips, subject, the model's reasoning, and Not Spam /
/// Spam. Not `MailRowView`: this screen has its own anatomy, with no avatar and a reasoning
/// line instead of a snippet.
private struct SpamReviewRow: View {
    let item: SpamReviewItem
    let accountChip: String?
    let onNotSpam: () -> Void
    let onSpam: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(extractSenderName(item.fromAddr)).font(.subheadline).bold().lineLimit(1)
                if item.isJunk {
                    Chip(text: "Junk", tint: .orange)
                }
                if let accountChip {
                    Chip(text: accountChip, tint: .secondary)
                }
                Spacer()
                Text(MVDateFormat.relativeDate(item.receivedAt)).font(.caption).foregroundStyle(.secondary)
            }
            // The address, and the envelope sender when it differs: a display name alone is
            // exactly what a mail impersonating the account's own domain fakes.
            Text(extractEmail(item.fromAddr)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let envelopeSender = distinctEnvelopeSender(item.envelopeSender, from: item.fromAddr) {
                Text("Envelope sender: \(envelopeSender)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let subject = item.subject {
                Text(subject).font(.subheadline)
            }
            if let reasoning = item.reasoning {
                Text(reasoning).font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                if let modelUsed = item.modelUsed {
                    Text(modelUsed).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(action: onNotSpam) {
                    Label("Not Spam", mvSymbol: MVSymbols.notSpam).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                Button(action: onSpam) {
                    Label("Spam", mvSymbol: MVSymbols.spam).labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
