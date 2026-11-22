import Foundation

public enum DeepLink: Equatable, Sendable {
    case record
    case session
    case trends
    case coach

    public static let scheme = "buddy"

    public var url: URL {
        switch self {
        case .record: return URL(string: "buddy://record")!
        case .session: return URL(string: "buddy://session")!
        case .trends: return URL(string: "buddy://trends")!
        case .coach: return URL(string: "buddy://coach")!
        }
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "record": self = .record
        case "session": self = .session
        case "trends": self = .trends
        case "coach": self = .coach
        default: return nil
        }
    }
}
