import SwiftUI
import WidgetKit

enum BuddyWidgetTheme {
    static let lightCobalt = Color(red: 0.039, green: 0.4, blue: 1.0)
    static let darkCobalt = Color(red: 0.231, green: 0.510, blue: 0.965)

    static func cobalt(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkCobalt : lightCobalt
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
        let snapshot = context.isPreview ? WidgetSnapshot.placeholder : WidgetSnapshot.load()
        completion(BuddyWidgetEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BuddyWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.load()
        let entry = BuddyWidgetEntry(date: now, snapshot: snapshot)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: now)
            ?? now.addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct BuddyHomeWidget: Widget {
    let kind: String = "BuddyHomeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BuddyTimelineProvider()) { entry in
            BuddyHomeWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Buddy Workout")
        .description("Glance at today's workout, weekly consistency, and log sets with one tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct BuddyHomeWidgetView: View {
    let entry: BuddyWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemSmall:
            SmallHomeWidgetView(snapshot: entry.snapshot)
                .widgetURL(DeepLink.record.url)
        case .systemMedium:
            MediumHomeWidgetView(snapshot: entry.snapshot)
                .widgetURL(DeepLink.record.url)
        case .systemLarge:
            LargeHomeWidgetView(snapshot: entry.snapshot)
                .widgetURL(DeepLink.record.url)
        default:
            SmallHomeWidgetView(snapshot: entry.snapshot)
                .widgetURL(DeepLink.record.url)
        }
    }
}

// MARK: - Small Widget

private struct SmallHomeWidgetView: View {
    let snapshot: WidgetSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var cobalt: Color {
        BuddyWidgetTheme.cobalt(for: colorScheme)
    }

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
                        .fill(cobalt)
                        .frame(width: 7, height: 7)
                    Text(active.startedAt, style: .timer)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(cobalt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(snapshot.currentStreakDays > 0 ? .orange : .secondary)
                    Text("\(snapshot.currentStreakDays)d streak")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(displaySets)")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(displaySets == 1 ? "set" : "sets")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(
                    displayVolumeKg > 0
                        ? snapshot.preferredUnit.formatVolume(kg: displayVolumeKg)
                        : (snapshot.activeSession?.title ?? "Ready to train")
                )
                .font(.system(.caption, design: .rounded, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 2)

            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("Record")
                    .font(.system(.caption, design: .rounded, weight: .bold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(cobalt, in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Medium Widget

private struct MediumHomeWidgetView: View {
    let snapshot: WidgetSnapshot

    @Environment(\.colorScheme) private var colorScheme

    private var cobalt: Color {
        BuddyWidgetTheme.cobalt(for: colorScheme)
    }

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
        if let todayFirst = snapshot.todayExercises.last?.name {
            return todayFirst
        }
        return "No sets logged yet"
    }

    private var lastExerciseDetail: String {
        if let activeSummary = snapshot.activeSession?.lastSetSummary {
            return activeSummary
        }
        if let todaySummary = snapshot.todayExercises.last?.summary {
            return todaySummary
        }
        return "Tap to log by voice"
    }

    private var weekDays: [DayActivitySnapshot] {
        snapshot.weeklyDays.isEmpty ? WidgetSnapshot.empty.weeklyDays : snapshot.weeklyDays
    }

    var body: some View {
        HStack(spacing: 14) {
            // Left: Active/Today stats + 7-day consistency bar strip
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let active = snapshot.activeSession {
                        Circle()
                            .fill(cobalt)
                            .frame(width: 7, height: 7)
                        Text(active.title)
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .foregroundStyle(cobalt)
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(active.startedAt, style: .timer)
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 48, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    } else {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snapshot.currentStreakDays > 0 ? .orange : .secondary)
                        Text("\(snapshot.currentStreakDays)d streak")
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(displaySets)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Text(displaySets == 1 ? "set" : "sets")
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(
                        displayVolumeKg > 0
                            ? snapshot.preferredUnit.formatVolume(kg: displayVolumeKg)
                            : "\(snapshot.workoutsThisWeek)/\(max(1, snapshot.weeklyGoal)) this week"
                    )
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 0)

                WeeklyConsistencyStrip(days: weekDays, accent: cobalt, barHeight: 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Right: 1-tap Record Set button + last logged exercise summary
            VStack(alignment: .leading, spacing: 10) {
                Link(destination: DeepLink.record.url) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Record Set")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("LAST LOGGED")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)

                    Text(lastExerciseTitle)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(lastExerciseDetail)
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private var cobalt: Color {
        BuddyWidgetTheme.cobalt(for: colorScheme)
    }

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
            // Header with streak badge and active/today status
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    if let active = snapshot.activeSession {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(cobalt)
                                .frame(width: 8, height: 8)
                            Text(active.title)
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(active.startedAt, style: .timer)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(cobalt)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: 52, alignment: .leading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            Text("· \(displaySets) sets · \(snapshot.preferredUnit.formatVolume(kg: displayVolumeKg))")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                    } else {
                        Text("Today's Workout")
                            .font(.system(.headline, design: .rounded, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("\(displaySets) sets · \(snapshot.preferredUnit.formatVolume(kg: displayVolumeKg))")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(snapshot.currentStreakDays > 0 ? .orange : .secondary)
                    Text("\(snapshot.currentStreakDays)d")
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.fill.quaternary, in: Capsule())
            }

            // 7-Day Volume Mini Bar Chart
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("7-DAY VOLUME")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    Spacer()
                    Text("\(snapshot.workoutsThisWeek)/\(max(1, snapshot.weeklyGoal)) weekly goal")
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(cobalt)
                }

                WeeklyConsistencyStrip(days: weekDays, accent: cobalt, barHeight: 42)
            }
            .padding(10)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            // Today's Logged Exercises (up to 4 rows)
            VStack(alignment: .leading, spacing: 6) {
                Text("EXERCISES")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                if snapshot.todayExercises.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(cobalt)
                        Text("No exercises logged today. Tap below and speak your set.")
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else {
                    ForEach(Array(snapshot.todayExercises.prefix(4))) { exercise in
                        HStack(spacing: 8) {
                            Text(exercise.name)
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(exercise.summary)
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Spacer(minLength: 0)

            // Full-width cobalt Voice Log CTA
            Link(destination: DeepLink.record.url) {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .bold))
                    Text("Record Voice Set")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared 7-Day Bar Strip

private struct WeeklyConsistencyStrip: View {
    let days: [DayActivitySnapshot]
    let accent: Color
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
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: barHeight)

                        Capsule()
                            .fill(isActiveDay ? (day.isToday ? accent : accent.opacity(0.65)) : Color.primary.opacity(0.12))
                            .frame(height: max(4, barHeight * normalized))
                    }

                    Text(day.weekdayLabel)
                        .font(.system(size: 9, weight: day.isToday ? .bold : .medium, design: .rounded))
                        .foregroundStyle(day.isToday ? accent : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
