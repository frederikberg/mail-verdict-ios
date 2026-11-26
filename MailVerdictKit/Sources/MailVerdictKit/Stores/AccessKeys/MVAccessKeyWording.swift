import Foundation

/// How an access key reads in a list: its name, whether it still works, and what it may do in
/// plain words. The web's `lib/access-keys.ts` says the same things the same way.
public enum MVAccessKeyState: Sendable, Equatable {
    case active
    /// Attached but never used, so it has no sign-in to sign out yet.
    case unused
    case signedOut
}

extension AccessKeyResponse {
    /// Its label, else the subject it signs in as.
    public var displayName: String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? subject : trimmed
    }

    public var state: MVAccessKeyState {
        if revokedAt != nil { return .signedOut }
        return signInId == nil ? .unused : .active
    }

    /// Whether it can be signed out from here: only a key that has signed in has a sign-in to end.
    public var canSignOut: Bool { state == .active }

    /// When it was last used, signed out or turned away, as the list's small print.
    public func activityLine(now: Date = Date()) -> String {
        var parts: [String]
        switch state {
        case .signedOut: parts = ["signed out \(MVDateFormat.relativeAgo(revokedAt, now: now))"]
        case .unused: parts = ["not used yet"]
        case .active: parts = ["last used \(MVDateFormat.relativeAgo(lastSeenAt, now: now))"]
        }
        if let lastRefusalAt {
            parts.append("last turned away \(MVDateFormat.relativeAgo(lastRefusalAt, now: now))")
        }
        return parts.joined(separator: " · ")
    }

    /// One line per resource a scoped key holds ("Calendars: can read and change, only in Work"),
    /// none for a full-access key. `calendarNames` and `addressbookNames` name the collections a
    /// write limit points at; an id missing from them is counted, never dropped.
    public func grantLines(
        calendarNames: [UUID: String] = [:], addressbookNames: [UUID: String] = [:]
    ) -> [String] {
        guard access == .scoped else { return [] }
        return MVAccessResource.allCases.compactMap { resource in
            let level = resource.level(in: scopes)
            guard level != .none else { return nil }
            var line = "\(resource.title): \(level.words)"
            if level == .write {
                let limit = resource == .calendar ? calendarWriteIds : addressbookWriteIds
                let names = resource == .calendar ? calendarNames : addressbookNames
                line += resource.limitWords(limit, names: names)
            }
            return line
        }
    }
}

/// What a scoped key can never reach, which is everything its lines do not name.
public let mvScopedKeyExcludes = "Mail, settings and every other part of the account are closed to it."

/// What signing a key out does, said to whoever is about to.
public let mvAccessKeySignOutConsequence =
    "This access key stops working for good. A replacement is attached again on the web."

enum MVAccessResource: CaseIterable {
    case calendar, contacts

    enum Level: Equatable {
        case none, read, write

        var words: String {
            switch self {
            case .none: return "no access"
            case .read: return "can read"
            case .write: return "can read and change"
            }
        }
    }

    /// A write scope also reads.
    func level(in scopes: [String]) -> Level {
        let prefix = self == .calendar ? "calendar" : "contacts"
        if scopes.contains("\(prefix):write") { return .write }
        if scopes.contains("\(prefix):read") { return .read }
        return .none
    }

    var title: String { self == .calendar ? "Calendars" : "Contacts" }

    func limitWords(_ limit: [UUID]?, names: [UUID: String]) -> String {
        let one = self == .calendar ? "calendar" : "address book"
        guard let limit else { return ", in every \(one)" }
        let named = limit.compactMap { names[$0] }
        let unnamed = limit.count - named.count
        var parts = named
        if unnamed > 0 {
            parts.append(unnamed == 1 ? "one \(one) not listed here" : "\(unnamed) \(one)s not listed here")
        }
        return ", only in \(parts.joined(separator: ", "))"
    }
}
