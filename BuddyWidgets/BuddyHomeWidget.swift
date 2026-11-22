import SwiftUI
import WidgetKit

enum BuddyWidgetTheme {
    static let emeraldLive = Color(red: 34.0 / 255.0, green: 197.0 / 255.0, blue: 94.0 / 255.0)
    static let amberStreak = Color(red: 245.0 / 255.0, green: 158.0 / 255.0, blue: 11.0 / 255.0)

    static func canvas(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.04, green: 0.04, blue: 0.045) : Color.white
    }

    static func tile(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.12) : Color(red: 0.95, green: 0.95, blue: 0.96)
    }

    static func primaryInk(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white : Color(red: 0.06, green: 0.06, blue: 0.06)
    }

    static func inverseInk(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.05, green: 0.05, blue: 0.05) : Color.white
    }

    static func mutedText(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color(red: 0.63, green: 0.63, blue: 0.65) : Color(red: 0.38, green: 0.38, blue: 0.40)
    }

    static func border(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
}

struct BuddyWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct BuddyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BuddyWidgetEntry {
        BuddyWidgetEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (BuddyWidgetEntry) -> Void) {
        let now = Date()
        let snapshot = context.isPreview
            ? WidgetSnapshot.placeholder
            : WidgetSnapshot.load().normalized(for: now)
        completion(BuddyWidgetEntry(date: now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BuddyWidgetEntry>) -> Void) {
        let now = Date()
        let calendar = Calendar.current
        let snapshot = WidgetSnapshot.load().normalized(for: now)
        let entry = BuddyWidgetEntry(date: now, snapshot: snapshot)

        let halfHour = calendar.date(byAdding: .minute, value: 30, to: now)
            ?? now.addingTimeInterval(1800)
        let nextMidnight = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 5),
            matchingPolicy: .nextTime
        ) ?? halfHour
        let nextRefresh = min(halfHour, nextMidnight)

        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct BuddyHomeWidget: Widget {
    let kind: String = "BuddyHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BuddyTimelineProvider()) { entry in
            BuddyHomeWidgetView(entry: entry)
        }
        .configurationDisplayName("Buddy Workout")
        .description("Glance at today's workout, weekly consistency, and log sets with one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct BuddyHomeWidgetView: View {
    let entry: BuddyWidgetEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                SmallHomeWidgetView(snapshot: entry.snapshot)
                    .widgetURL(DeepLink.record.url)
            case .systemMedium:
                MediumHomeWidgetView(snapshot: entry.snapshot)
                    .widgetURL(DeepLink.session.url)
            case .systemLarge:
                LargeHomeWidgetView(snapshot: entry.snapshot)
                    .widgetURL(DeepLink.session.url)
            default:
                SmallHomeWidgetView(snapshot: entry.snapshot)
                    .widgetURL(DeepLink.record.url)
            }
        }
        .containerBackground(BuddyWidgetTheme.canvas(for: colorScheme), for: .widget)
    }
}

// MARK: - Small Widget

private struct SmallHomeWidgetView: View {
    let snapshot: WidgetSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var primaryInk: Color { BuddyWidgetTheme.primaryInk(for: colorScheme) }
    private var inverseInk: Color { BuddyWidgetTheme.inverseInk(for: colorScheme) }
    private var muted: Color { BuddyWidgetTheme.mutedText(for: colorScheme) }

    private var displaySets: Int {
        snapshot.activeSession?.totalSets ?? snapshot.todaySets
    }

    private var displayVolumeKg: Double {
        snapshot.activeSession?.totalVolumeKg ?? snapshot.todayVolumeKg
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                if let active = snapshot.activeSession {
                    Circle()
                        .fill(BuddyWidgetTheme.emeraldLive)
                        .frame(width: 6, height: 6)
                    Text(active.startedAt, style: .timer)
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(BuddyWidgetTheme.emeraldLive)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                } else {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(snapshot.currentStreakDays > 0 ? BuddyWidgetTheme.amberStreak : muted)
                    Text("\(snapshot.currentStreakDays)d streak")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(displaySets)")
                        .font(.system(size: 32, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(displaySets == 1 ? "set" : "sets")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(muted)
                }

                Text(
                    displayVolumeKg > 0
                        ? snapshot.preferredUnit.formatVolume(kg: displayVolumeKg)
                        : (snapshot.activeSession?.title ?? "Ready to train")
                )
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(muted)
                .lineLimit(1)
            }

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 11.5, weight: .bold))
                Text("Record")
                    .font(.system(size: 12.5, weight: .bold))
            }
            .foregroundStyle(inverseInk)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(primaryInk, in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium Widget

private struct MediumHomeWidgetView: View {
    let snapshot: WidgetSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var primaryInk: Color { BuddyWidgetTheme.primaryInk(for: colorScheme) }
    private var inverseInk: Color { BuddyWidgetTheme.inverseInk(for: colorScheme) }
    private var muted: Color { BuddyWidgetTheme.mutedText(for: colorScheme) }
    private var tile: Color { BuddyWidgetTheme.tile(for: colorScheme) }
    private var border: Color { BuddyWidgetTheme.border(for: colorScheme) }

    private var displaySets: Int {
        snapshot.activeSession?.totalSets ?? snapshot.todaySets
    }

    private var displayVolumeKg: Double {
        snapshot.activeSession?.totalVolumeKg ?? snapshot.todayVolumeKg
    }

    private var lastExerciseTitle: String {
        if let activeName = snapshot.activeSession?.lastExerciseName {
            return activeName
        }
        if let latestToday = snapshot.lastTodayExerciseName {
            return latestToday
        }
        if let fallback = snapshot.todayExercises.first?.name {
            return fallback
        }
        return "No sets logged yet"
    }

    private var lastExerciseDetail: String {
        if let activeSummary = snapshot.activeSession?.lastSetSummary {
            return activeSummary
        }
        if let latestSummary = snapshot.lastTodaySetSummary {
            return latestSummary
        }
        if let fallback = snapshot.todayExercises.first?.summary {
            return fallback
        }
        return "Tap to log by voice"
    }

    private var weekDays: [DayActivitySnapshot] {
        snapshot.weeklyDays.isEmpty ? WidgetSnapshot.empty.weeklyDays : snapshot.weeklyDays
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let active = snapshot.activeSession {
                        Circle()
                            .fill(BuddyWidgetTheme.emeraldLive)
                            .frame(width: 6, height: 6)
                        Text(active.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(primaryInk)
                            .lineLimit(1)
                        Text(active.startedAt, style: .timer)
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyWidgetTheme.emeraldLive)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 58, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    } else {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snapshot.currentStreakDays > 0 ? BuddyWidgetTheme.amberStreak : muted)
                        Text("\(snapshot.currentStreakDays)d streak")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(muted)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(displaySets)")
                            .font(.system(size: 28, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(primaryInk)
                        Text(displaySets == 1 ? "set" : "sets")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(muted)
                    }
                    Text(
                        displayVolumeKg > 0
                            ? snapshot.preferredUnit.formatVolume(kg: displayVolumeKg)
                            : "\(snapshot.workoutsThisWeek)/\(max(1, snapshot.weeklyGoal)) this week"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(muted)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                WeeklyConsistencyStrip(days: weekDays, accent: primaryInk, muted: muted, barHeight: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 9) {
                Link(destination: DeepLink.record.url) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Record Set")
                            .font(.system(size: 13.5, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(inverseInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(primaryInk, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST LOGGED")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(muted)
                        .tracking(0.5)

                    Text(lastExerciseTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)

                    Text(lastExerciseDetail)
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(muted)
                        .lineLimit(1)
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(tile, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(border, lineWidth: 0.75)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Large Widget

private struct LargeHomeWidgetView: View {
    let snapshot: WidgetSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var primaryInk: Color { BuddyWidgetTheme.primaryInk(for: colorScheme) }
    private var inverseInk: Color { BuddyWidgetTheme.inverseInk(for: colorScheme) }
    private var muted: Color { BuddyWidgetTheme.mutedText(for: colorScheme) }
    private var tile: Color { BuddyWidgetTheme.tile(for: colorScheme) }
    private var border: Color { BuddyWidgetTheme.border(for: colorScheme) }

    private var displaySets: Int {
        snapshot.activeSession?.totalSets ?? snapshot.todaySets
    }

    private var displayVolumeKg: Double {
        snapshot.activeSession?.totalVolumeKg ?? snapshot.todayVolumeKg
    }

    private var weekDays: [DayActivitySnapshot] {
        snapshot.weeklyDays.isEmpty ? WidgetSnapshot.empty.weeklyDays : snapshot.weeklyDays
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let active = snapshot.activeSession {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(BuddyWidgetTheme.emeraldLive)
                                .frame(width: 7, height: 7)
                            Text(active.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(primaryInk)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(active.startedAt, style: .timer)
                                .font(.system(size: 12, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(BuddyWidgetTheme.emeraldLive)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 66, alignment: .leading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text("· \(displaySets) sets · \(snapshot.preferredUnit.formatVolume(kg: displayVolumeKg))")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(muted)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Today's Workout")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(primaryInk)
                        Text("\(displaySets) sets · \(snapshot.preferredUnit.formatVolume(kg: displayVolumeKg))")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(muted)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(snapshot.currentStreakDays > 0 ? BuddyWidgetTheme.amberStreak : muted)
                    Text("\(snapshot.currentStreakDays)d")
                        .font(.system(size: 12, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(primaryInk)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tile, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(border, lineWidth: 0.75)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("7-DAY VOLUME")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(muted)
                        .tracking(0.5)
                    Spacer()
                    Text("\(snapshot.workoutsThisWeek)/\(max(1, snapshot.weeklyGoal)) weekly goal")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(primaryInk)
                }

                WeeklyConsistencyStrip(days: weekDays, accent: primaryInk, muted: muted, barHeight: 42)
            }
            .padding(10)
            .background(tile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.75)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("EXERCISES")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(muted)
                    .tracking(0.5)

                if snapshot.todayExercises.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(muted)
                        Text("No exercises logged today. Tap below and speak your set.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(muted)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    ForEach(Array(snapshot.todayExercises.prefix(4))) { exercise in
                        HStack(spacing: 8) {
                            Text(exercise.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(primaryInk)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(exercise.summary)
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(muted)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Spacer(minLength: 0)

            Link(destination: DeepLink.record.url) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text("Record Voice Set")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(inverseInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(primaryInk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared 7-Day Monochrome Bar Strip

private struct WeeklyConsistencyStrip: View {
    let days: [DayActivitySnapshot]
    let accent: Color
    let muted: Color
    let barHeight: CGFloat

    private var maxMetric: Double {
        let maxVolume = days.map(\.volumeKg).max() ?? 0
        if maxVolume > 0 {
            return maxVolume
        }
        return Double(max(1, days.map(\.setCount).max() ?? 1))
    }

    private var useVolume: Bool {
        (days.map(\.volumeKg).max() ?? 0) > 0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days.suffix(7)) { day in
                let rawValue = useVolume ? day.volumeKg : Double(day.setCount)
                let isActiveDay = day.setCount > 0 || day.volumeKg > 0
                let normalized = isActiveDay ? max(0.18, min(1.0, rawValue / maxMetric)) : 0.12

                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        Capsule()
                            .fill(accent.opacity(0.08))
                            .frame(height: barHeight)

                        Capsule()
                            .fill(isActiveDay ? (day.isToday ? accent : accent.opacity(0.55)) : accent.opacity(0.14))
                            .frame(height: max(4, barHeight * normalized))
                    }

                    Text(day.weekdayLabel)
                        .font(.system(size: 9, weight: day.isToday ? .bold : .medium))
                        .foregroundStyle(day.isToday ? accent : muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
