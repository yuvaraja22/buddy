import SwiftUI
import UIKit

public enum BuddyAppearance: String, CaseIterable, Identifiable, Codable, Sendable {
    case dark
    case light
    case system

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dark: return "Dark (OLED)"
        case .light: return "Light"
        case .system: return "System"
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
}

public enum BuddyTheme {
    /// High-contrast monochrome primary ink (pure white in dark OLED, near-black in light).
    /// Mirrors YouTube/Uber active chips and primary action buttons.
    public static let inkPrimary = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white
            }
            return UIColor(red: 15.0 / 255.0, green: 15.0 / 255.0, blue: 15.0 / 255.0, alpha: 1.0)
        }
    )

    /// Inverse text/icon ink rendered on top of `inkPrimary` buttons and active chips.
    public static let inkInverse = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, alpha: 1.0)
            }
            return UIColor.white
        }
    )

    /// Legacy accent aliases mapped to clean monochrome so zero Apple-blue washes leak through.
    public static let cobalt = inkPrimary
    public static let cobaltDeep = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 229.0 / 255.0, green: 229.0 / 255.0, blue: 229.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0)
        }
    )
    public static let cobaltSoft = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.11)
            }
            return UIColor.black.withAlphaComponent(0.07)
        }
    )

    /// Surgical live-session & readiness green dot.
    public static let emeraldLive = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 34.0 / 255.0, green: 197.0 / 255.0, blue: 94.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 22.0 / 255.0, green: 163.0 / 255.0, blue: 74.0 / 255.0, alpha: 1.0)
        }
    )

    /// Surgical amber accent for streaks, warnings, and warmup badges.
    public static let amberStreak = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 217.0 / 255.0, green: 119.0 / 255.0, blue: 6.0 / 255.0, alpha: 1.0)
        }
    )

    /// Neutral silver-slate tag for drop sets.
    public static let indigoTag = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 161.0 / 255.0, green: 161.0 / 255.0, blue: 170.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 82.0 / 255.0, green: 82.0 / 255.0, blue: 91.0 / 255.0, alpha: 1.0)
        }
    )

    /// Crisp signal red for active recording, destructive actions, and failure tags.
    public static let destructive = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 239.0 / 255.0, green: 68.0 / 255.0, blue: 68.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 220.0 / 255.0, green: 38.0 / 255.0, blue: 38.0 / 255.0, alpha: 1.0)
        }
    )

    /// True OLED pitch-black canvas in dark mode, clean white in light mode.
    public static let canvasBackground = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.black
            }
            return UIColor.white
        }
    )

    /// Matte obsidian charcoal primary surface (#141414 dark / #F6F6F6 light).
    public static let cardSurface = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 20.0 / 255.0, green: 20.0 / 255.0, blue: 20.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 246.0 / 255.0, green: 246.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0)
        }
    )

    /// Elevated charcoal tile / pill fill (#1F1F1F dark / #ECECEC light).
    public static let elevatedSurface = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 31.0 / 255.0, green: 31.0 / 255.0, blue: 31.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 236.0 / 255.0, green: 236.0 / 255.0, blue: 236.0 / 255.0, alpha: 1.0)
        }
    )

    /// YouTube-style inactive filter chip surface (#272727 dark / #EDEDED light).
    public static let chipSurface = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 39.0 / 255.0, green: 39.0 / 255.0, blue: 39.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 237.0 / 255.0, green: 237.0 / 255.0, blue: 237.0 / 255.0, alpha: 1.0)
        }
    )

    /// Floating Uber-style dark navigation bar surface.
    public static let floatingBarSurface = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 24.0 / 255.0, alpha: 0.96)
            }
            return UIColor(red: 250.0 / 255.0, green: 250.0 / 255.0, blue: 250.0 / 255.0, alpha: 0.96)
        }
    )

    /// Secondary text matching YouTube/Uber muted silver gray (#A0A0A0 dark / #5C5C5C light).
    public static let mutedText = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor(red: 160.0 / 255.0, green: 160.0 / 255.0, blue: 160.0 / 255.0, alpha: 1.0)
            }
            return UIColor(red: 92.0 / 255.0, green: 92.0 / 255.0, blue: 92.0 / 255.0, alpha: 1.0)
        }
    )

    /// Crisp subtle 1px card border.
    public static let hairlineBorder = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.10)
            }
            return UIColor.black.withAlphaComponent(0.08)
        }
    )

    /// Crisp border for floating pills, docks, and command inputs.
    public static let glassBorder = Color(
        uiColor: UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                return UIColor.white.withAlphaComponent(0.14)
            }
            return UIColor.black.withAlphaComponent(0.11)
        }
    )

    /// Monochrome intensity heatmap ramp across levels 0...4.
    public static func heatmapColor(for intensity: Int) -> Color {
        switch intensity {
        case 0:
            return elevatedSurface
        case 1:
            return inkPrimary.opacity(0.24)
        case 2:
            return inkPrimary.opacity(0.46)
        case 3:
            return inkPrimary.opacity(0.72)
        default:
            return inkPrimary
        }
    }

    public static func tagTint(for tag: SetTag) -> Color {
        switch tag {
        case .normal: return inkPrimary
        case .warmup: return amberStreak
        case .dropset: return indigoTag
        case .failure: return destructive
        }
    }

    // MARK: Typography (Sharp Utilitarian Sans-Serif — Zero Rounded Bubble Fonts)

    public static let heroMetricFont = Font.system(size: 28, weight: .bold, design: .default)
    public static let statValueFont = Font.system(size: 19, weight: .bold, design: .default)
    public static let compactMetricFont = Font.system(size: 16, weight: .bold, design: .default)
    public static let sectionTitleFont = Font.system(size: 18, weight: .bold, design: .default)
    public static let captionLabelFont = Font.system(size: 11, weight: .semibold, design: .default)

    // MARK: Layout Metrics

    public static let cardCornerRadius: CGFloat = 14
    public static let cardPadding: CGFloat = 14
    /// Standard bottom padding so scrolled feeds clear the floating Uber pill bar + Mic button.
    public static let floatingBarClearance: CGFloat = 104
}

public extension View {
    /// Applies crisp tabular numerals without Apple's rounded font style.
    func buddyNumeric() -> some View {
        self.monospacedDigit()
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

// MARK: - Reusable Monochrome Components

public struct NativeCard<Content: View>: View {
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
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(BuddyTheme.cardSurface)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        tint?.opacity(0.35) ?? BuddyTheme.hairlineBorder,
                        lineWidth: 0.9
                    )
            }
    }
}

/// YouTube-style crisp rectangular filter chip (solid white/black when selected, dark gray when idle).
public struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    public init(title: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button {
            BuddyHaptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? BuddyTheme.inkInverse : Color.primary)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                )
        }
        .buttonStyle(.plain)
    }
}

/// YouTube-inspired 16:9 dark workout artwork tile with crisp corner metadata badges.
public struct WorkoutThumbnailView: View {
    let assetName: String
    let bottomRightBadge: String
    let topLeftTag: String?
    let isLiveTag: Bool
    let width: CGFloat
    let height: CGFloat

    public init(
        assetName: String,
        bottomRightBadge: String,
        topLeftTag: String? = nil,
        isLiveTag: Bool = false,
        width: CGFloat = 136,
        height: CGFloat = 80
    ) {
        self.assetName = assetName
        self.bottomRightBadge = bottomRightBadge
        self.topLeftTag = topLeftTag
        self.isLiveTag = isLiveTag
        self.width = width
        self.height = height
    }

    public var body: some View {
        ZStack {
            Image(assetName)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipped()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.05),
                    Color.black.opacity(0.45)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack {
                HStack {
                    if let topLeftTag, !topLeftTag.isEmpty {
                        HStack(spacing: 4) {
                            if isLiveTag {
                                Circle()
                                    .fill(BuddyTheme.emeraldLive)
                                    .frame(width: 5, height: 5)
                            }
                            Text(topLeftTag)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.black)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white)
                        )
                    }
                    Spacer(minLength: 0)
                }

                Spacer(minLength: 0)

                HStack {
                    Spacer(minLength: 0)
                    if !bottomRightBadge.isEmpty {
                        Text(bottomRightBadge)
                            .font(.system(size: 10, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.black.opacity(0.78))
                            )
                    }
                }
            }
            .padding(6)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.75)
        }
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
        tint: Color = BuddyTheme.inkPrimary,
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
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title.uppercased())
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(BuddyTheme.mutedText)
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
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
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
        tint: Color = BuddyTheme.inkPrimary,
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
                PulsingLiveDot(color: tint, size: 6)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }

            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.75)
        }
    }
}

public struct PulsingLiveDot: View {
    private let color: Color
    private let size: CGFloat
    @State private var isAnimating = false

    public init(color: Color = BuddyTheme.emeraldLive, size: CGFloat = 7) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.0, height: size * 2.0)
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
