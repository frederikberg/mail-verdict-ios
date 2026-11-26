import Foundation

/// Whether a sign-in may do everything its user may (`full`) or exactly a list of scopes
/// (`scoped`). A value this build does not know decodes as `unrecognized` instead of failing the
/// whole answer.
public enum MVAccessMode: Sendable, Equatable, Codable {
    case full
    case scoped
    case unrecognized(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "full": self = .full
        case "scoped": self = .scoped
        default: self = .unrecognized(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .full: try container.encode("full")
        case .scoped: try container.encode("scoped")
        case .unrecognized(let raw): try container.encode(raw)
        }
    }
}

/// What the caller's own sign-in may do (`MeResponse.access`). A write scope implies its read
/// scope; a write limit of `nil` means every calendar or address book.
public struct AccessResponse: ContractModel, Codable, Sendable, Equatable {
    public static let schemaName = "AccessResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case mode, scopes
        case calendarWriteIds = "calendar_write_ids"
        case addressbookWriteIds = "addressbook_write_ids"
    }
    public typealias CodingKeys = ContractKeys

    public let mode: MVAccessMode
    public let scopes: [String]
    public let calendarWriteIds: [UUID]?
    public let addressbookWriteIds: [UUID]?

    public init(mode: MVAccessMode, scopes: [String], calendarWriteIds: [UUID]?, addressbookWriteIds: [UUID]?) {
        self.mode = mode
        self.scopes = scopes
        self.calendarWriteIds = calendarWriteIds
        self.addressbookWriteIds = addressbookWriteIds
    }
}

/// One access key as `GET /api/me/access-keys` lists it: an agent, script or other client that
/// signs in as the caller, and what it may do. The sign-in fields stay `nil` until the key has
/// been used; signing it out goes through its sign-in.
public struct AccessKeyResponse: ContractModel, Codable, Sendable, Equatable, Identifiable {
    public static let schemaName = "AccessKeyResponse"
    public enum ContractKeys: String, CodingKey, CaseIterable {
        case subject, label
        case userId = "user_id"
        case userDisplayName = "user_display_name"
        case access, scopes
        case calendarWriteIds = "calendar_write_ids"
        case addressbookWriteIds = "addressbook_write_ids"
        case createdAt = "created_at"
        case signInId = "sign_in_id"
        case firstSeenAt = "first_seen_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
        case lastRefusalAt = "last_refusal_at"
    }
    public typealias CodingKeys = ContractKeys

    public let subject: String
    public let label: String?
    public let userId: UUID
    public let userDisplayName: String
    public let access: MVAccessMode
    public let scopes: [String]
    public let calendarWriteIds: [UUID]?
    public let addressbookWriteIds: [UUID]?
    public let createdAt: Date
    public let signInId: UUID?
    public let firstSeenAt: Date?
    public let lastSeenAt: Date?
    public let revokedAt: Date?
    public let lastRefusalAt: Date?

    public var id: String { subject }

    public init(
        subject: String, label: String?, userId: UUID, userDisplayName: String, access: MVAccessMode,
        scopes: [String], calendarWriteIds: [UUID]?, addressbookWriteIds: [UUID]?, createdAt: Date,
        signInId: UUID?, firstSeenAt: Date?, lastSeenAt: Date?, revokedAt: Date?, lastRefusalAt: Date?
    ) {
        self.subject = subject
        self.label = label
        self.userId = userId
        self.userDisplayName = userDisplayName
        self.access = access
        self.scopes = scopes
        self.calendarWriteIds = calendarWriteIds
        self.addressbookWriteIds = addressbookWriteIds
        self.createdAt = createdAt
        self.signInId = signInId
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.revokedAt = revokedAt
        self.lastRefusalAt = lastRefusalAt
    }
}
