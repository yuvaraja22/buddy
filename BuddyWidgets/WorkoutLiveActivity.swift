#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutLiveActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .widgetURL(DeepLink.session.url)
                .activitySystemActionForegroundColor(BuddyWidgetTheme.lightCobalt)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "dumbbell.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(BuddyWidgetTheme.darkCobalt)
                            Text(context.state.sessionTitle)
                                .font(.system(.caption, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        Text("\(context.state.totalSets) sets")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.sessionStartedAt, style: .timer)
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyWidgetTheme.darkCobalt)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 82, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(
                            context.state.totalVolumeKg > 0
                                ? context.state.preferredUnit.formatVolume(kg: context.state.totalVolumeKg)
                                : "\(context.state.totalReps) reps"
                        )
                        .font(.system(.caption2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                context.state.lastExerciseName.isEmpty
                                    ? "Ready to log"
                                    : context.state.lastExerciseName
                            )
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                            Text(
                                context.state.lastSetDetail.isEmpty
                                    ? "Tap Voice Log to record a set"
                                    : context.state.lastSetDetail
                            )
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Link(destination: DeepLink.record.url) {
                            HStack(spacing: 5) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 12, weight: .bold))
                                Text("Voice Log")
                                    .font(.system(.caption, design: .rounded, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(BuddyWidgetTheme.darkCobalt, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(BuddyWidgetTheme.darkCobalt)
                    .padding(.leading, 2)
            } compactTrailing: {
                Text(context.attributes.sessionStartedAt, style: .timer)
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 58, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } minimal: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(BuddyWidgetTheme.darkCobalt)
            }
            .keylineTint(BuddyWidgetTheme.darkCobalt)
            .widgetURL(DeepLink.session.url)
        }
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutLiveActivityAttributes>

    @Environment(\.colorScheme) private var colorScheme

    private var cobalt: Color {
        BuddyWidgetTheme.cobalt(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top Row: Session Title + Live Ticking Timer
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(cobalt)
                        .frame(width: 8, height: 8)
                    Text(context.state.sessionTitle)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(cobalt)
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(cobalt)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 84, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            // Middle Row: Sets & Volume Counters
            HStack(spacing: 12) {
                LiveStatPill(
                    label: "SETS",
                    value: "\(context.state.totalSets)"
                )
                LiveStatPill(
                    label: "VOLUME",
                    value: context.state.totalVolumeKg > 0
                        ? context.state.preferredUnit.formatVolume(kg: context.state.totalVolumeKg)
                        : "\(context.state.totalReps) reps"
                )
                LiveStatPill(
                    label: "EXERCISES",
                    value: "\(context.state.exerciseCount)"
                )
            }

            // Bottom Row: Last Logged Exercise + 1-Tap Cobalt Log Set Button
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        context.state.lastExerciseName.isEmpty
                            ? "Workout active"
                            : context.state.lastExerciseName
                    )
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                    Text(
                        context.state.lastSetDetail.isEmpty
                            ? "Tap Log Set to record by voice"
                            : context.state.lastSetDetail
                    )
                    .font(.system(.caption2, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Link(destination: DeepLink.record.url) {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Log Set")
                            .font(.system(.caption, design: .rounded, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(cobalt, in: Capsule())
                }
            }
        }
        .padding(14)
    }
}

private struct LiveStatPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(0.4)
            Text(value)
                .font(.system(.footnote, design: .rounded, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
#endif
