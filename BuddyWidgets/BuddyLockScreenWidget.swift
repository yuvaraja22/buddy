import SwiftUI
import WidgetKit

struct BuddyLockScreenWidget: Widget {
    let kind: String = "BuddyLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BuddyTimelineProvider()) { entry in
            BuddyLockScreenWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Buddy Quick Log")
        .description("Launch voice logging and track daily workout progress from your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct BuddyLockScreenWidgetView: View {
    let entry: BuddyWidgetEntry

    @Environment(\.widgetFamily) private var family

    private var displaySets: Int {
        entry.snapshot.activeSession?.totalSets ?? entry.snapshot.todaySets
    }

    private var displayVolumeKg: Double {
        entry.snapshot.activeSession?.totalVolumeKg ?? entry.snapshot.todayVolumeKg
    }

    private var lastExerciseLine: String {
        if let activeName = entry.snapshot.activeSession?.lastExerciseName {
            return activeName
        }
        if let latest = entry.snapshot.lastTodayExerciseName {
            return latest
        }
        if let fallback = entry.snapshot.todayExercises.first?.name {
            return fallback
        }
        return "Tap to log voice set"
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circularView
            case .accessoryRectangular:
                rectangularView
            case .accessoryInline:
                inlineView
            default:
                circularView
            }
        }
        .widgetURL(DeepLink.record.url)
    }

    private var circularView: some View {
        let goal = Double(max(1, entry.snapshot.weeklyGoal))
        let progress = min(Double(entry.snapshot.workoutsThisWeek), goal)

        return Gauge(value: progress, in: 0...goal) {
            Image(systemName: "mic.fill")
        } currentValueLabel: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var rectangularView: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.snapshot.activeSession != nil ? "waveform" : "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(entry.snapshot.activeSession?.title ?? "Buddy")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }

            Text(
                displayVolumeKg > 0
                    ? "\(displaySets) sets · \(entry.snapshot.preferredUnit.formatVolume(kg: displayVolumeKg))"
                    : "\(displaySets) sets today"
            )
            .font(.system(size: 12, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)

            Text(lastExerciseLine)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineView: some View {
        Label(
            "\(entry.snapshot.currentStreakDays)d streak · \(displaySets) sets",
            systemImage: "flame.fill"
        )
    }
}
