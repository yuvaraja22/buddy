import Foundation

public enum WeightUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case kg
    case lbs

    public var id: String { rawValue }

    public var label: String { rawValue }

    public var displayName: String {
        switch self {
        case .kg: return "Kilograms (kg)"
        case .lbs: return "Pounds (lbs)"
        }
    }

    private static let lbsPerKg: Double = 2.2046226218

    public func toKg(_ value: Double) -> Double {
        switch self {
        case .kg: return value
        case .lbs: return value / Self.lbsPerKg
        }
    }

    public func fromKg(_ kg: Double) -> Double {
        switch self {
        case .kg: return kg
        case .lbs: return kg * Self.lbsPerKg
        }
    }

    public func formatWeight(kg: Double) -> String {
        let converted = fromKg(kg)
        let rounded = (converted * 10).rounded() / 10
        if rounded.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(rounded)) \(rawValue)"
        }
        return String(format: "%.1f %@", rounded, rawValue)
    }

    public func formatVolume(kg: Double) -> String {
        let converted = fromKg(kg)
        if converted >= 10_000 {
            return String(format: "%.1fk %@", converted / 1_000.0, rawValue)
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let formatted = formatter.string(from: NSNumber(value: converted.rounded())) ?? "\(Int(converted.rounded()))"
        return "\(formatted) \(rawValue)"
    }
}

public enum DurationFormatter {
    public static func formatClock(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public static func formatCompact(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 && minutes < 5 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }
}
