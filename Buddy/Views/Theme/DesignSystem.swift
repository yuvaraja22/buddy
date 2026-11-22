import SwiftUI
import UIKit

public enum BuddyTheme {
    /// Adaptive cobalt blue accent (#0A66FF light / #3B82F6 dark).
    public static let cobalt = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 10.0 / 255.0, green: 102.0 / 255.0, blue: 255.0 / 255.0, alpha: 1.0)
        }
    )

    /// Deeper cobalt stop for subtle Apple-native button gradients.
    public static let cobaltDeep = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 235.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 0.0 / 255.0, green: 82.0 / 255.0, blue: 224.0 / 255.0, alpha: 1.0)
        }
    )

    /// Soft translucent cobalt surface for pills, badges, and active highlights.
    public static let cobaltSoft = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0, alpha: 0.20)
            }
            return UIColor(red: 10.0 / 255.0, green: 102.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.11)
        }
    )

    /// Adaptive emerald indicator for active live workout sessions and success states.
    public static let emeraldLive = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 52.0 / 255.0, green: 211.0 / 255.0, blue: 153.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0, alpha: 1.0)
        }
    )

    /// Adaptive amber accent for streaks and warmup indicators.
    public static let amberStreak = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 251.0 / 255.0, green: 191.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
        }
    )

    /// Adaptive indigo tint for drop-set tags.
    public static let indigoTag = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 129.0 / 255.0, green: 140.0 / 255.0, blue: 248.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 79.0 / 255.0, green: 70.0 / 255.0, blue: 229.0 / 255.0, alpha: 1.0)
        }
    )

    public static let destructive = Color(uiColor: .systemRed)

    /// Grouped page background matching Apple Health.
    public static let canvasBackground = Color(uiColor: .systemGroupedBackground)

    /// Primary card surface.
    public static let cardSurface = Color(uiColor: .secondarySystemGroupedBackground)

    /// Nested tile / secondary surface inside cards.
    public static let elevatedSurface = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.tertiarySystemGroupedBackground
            }
            return UIColor.systemGroupedBackground.withAlphaComponent(0.72)
        }
    )

    /// Subtle crisp hairline card border.
    public static let hairlineBorder = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.09)
            }
            return UIColor.black.withAlphaComponent(0.06)
        }
    )

    /// Subtle specular hairline for frosted glass docks and toasts.
    public static let glassBorder = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.18)
            }
            return UIColor.black.withAlphaComponent(0.08)
        }
    )

    /// Heatmap color ramp across intensity levels 0...4.
    public static func heatmapColor(for intensity: Int) -> Color {
        switch intensity {
        case 0:
            return Color(uiColor: .tertiarySystemFill)
        case 1:
            return cobalt.opacity(0.26)
        case 2:
            return cobalt.opacity(0.50)
        case 3:
            return cobalt.opacity(0.76)
        default:
            return cobalt
        }
    }

    public static func tagTint(for tag: SetTag) -> Color {
        switch tag {
        case .normal: return cobalt
        case .warmup: return amberStreak
        case .dropset: return indigoTag
        case .failure: return destructive
        }
    }

    // MARK: Typography Helpers

    public static let heroMetricFont = Font.system(size: 30, weight: .bold, design: .rounded)
    public static let statValueFont = Font.system(size: 20, weight: .bold, design: .rounded)
    public static let compactMetricFont = Font.system(size: 16, weight: .semibold, design: .rounded)
    public static let sectionTitleFont = Font.system(.title3, design: .rounded, weight: .bold)
    public static let captionLabelFont = Font.system(size: 11, weight: .semibold, design: .default)

    // MARK: Layout Metrics

    public static let cardCornerRadius: CGFloat = 20
    public static let cardPadding: CGFloat = 16
}

public extension View {
    /// Applies crisp Apple Sports / Health rounded tabular numerals.
    func buddyNumeric() -> some View {
        self
            .fontDesign(.rounded)
            .monospacedDigit()
    }
}

// MARK: - Tactile Haptics

@MainActor
public enum BuddyHaptics {
    public static func lightImpact() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    public static func mediumImpact() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    public static func holdLockImpact() {
        let generator = UIImpactFeedbackGenerator(style: .rigid)
        generator.prepare()
        generator.impactOccurred(intensity: 0.85)
    }

    public static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    public static func success() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    public static func warning() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.warning)
    }

    public static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.error)
    }
}

// MARK: - Reusable Native Components

public struct NativeCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let padding: CGFloat
    private let cornerRadius: CGFloat
    private let tint: Color?
    private let content: Content

    public init(
        padding: CGFloat = BuddyTheme.cardPadding,
        cornerRadius: CGFloat = BuddyTheme.cardCornerRadius,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(BuddyTheme.cardSurface)
                    if let tint {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(tint.opacity(colorScheme == .dark ? 0.12 : 0.06))
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint?.opacity(colorScheme == .dark ? 0.28 : 0.18) ?? BuddyTheme.hairlineBorder,
                        lineWidth: 0.75
                    )
            }
            .shadow(
                color: colorScheme == .dark ? .clear : Color.black.opacity(0.035),
                radius: 10,
                x: 0,
                y: 3
            )
    }
}

public struct StatMetricTile: View {
    private let title: String
    private let value: String
    private let subtitle: String?
    private let icon: String?
    private let tint: Color
    private let compact: Bool

    public init(
        title: String,
        value: String,
        subtitle: String? = nil,
        icon: String? = nil,
        tint: Color = BuddyTheme.cobalt,
        compact: Bool = false
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.compact = compact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title.uppercased())
                    .font(.system(size: compact ? 10 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Text(value)
                .font(compact ? BuddyTheme.compactMetricFont : BuddyTheme.statValueFont)
                .buddyNumeric()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.75)
        }
    }
}

public struct StatusPill: View {
    private let text: String
    private let icon: String?
    private let tint: Color
    private let isPulsing: Bool

    public init(
        text: String,
        icon: String? = nil,
        tint: Color = BuddyTheme.cobalt,
        isPulsing: Bool = false
    ) {
        self.text = text
        self.icon = icon
        self.tint = tint
        self.isPulsing = isPulsing
    }

    public var body: some View {
        HStack(spacing: 5) {
            if isPulsing {
                PulsingLiveDot(color: tint, size: 7)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(tint.opacity(0.14))
        }
    }
}

public struct PulsingLiveDot: View {
    private let color: Color
    private let size: CGFloat
    @State private var isAnimating = false

    public init(color: Color = BuddyTheme.emeraldLive, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 1.9, height: size * 1.9)
                .scaleEffect(isAnimating ? 1.15 : 0.7)
                .opacity(isAnimating ? 0.15 : 0.65)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}
