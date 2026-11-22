#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutLiveActivityAttributes.self) { context in
            WorkoutLiveActivityLockScreenView(context: context)
                .widgetURL(DeepLink.session.url)
                .activityBackgroundTint(Color(red: 0.06, green: 0.06, blue: 0.07))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(BuddyWidgetTheme.emeraldLive)
                                .frame(width: 6, height: 6)
                            Text(context.state.sessionTitle)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        Text("\(context.state.totalSets) sets")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.attributes.sessionStartedAt, style: .timer)
                            .font(.system(size: 14, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 82, alignment: .trailing)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text(
                            context.state.totalVolumeKg > 0
                                ? context.state.preferredUnit.formatVolume(kg: context.state.totalVolumeKg)
                                : "\(context.state.totalReps) reps"
                        )
                        .font(.system(size: 11, weight: .semibold))
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
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                            Text(
                                context.state.lastSetDetail.isEmpty
                                    ? "Tap Voice Log to record a set"
                                    : context.state.lastSetDetail
                            )
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }

                        Spacer(minLength: 6)

                        Link(destination: DeepLink.record.url) {
                            HStack(spacing: 5) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 11.5, weight: .bold))
                                Text("Voice Log")
                                    .font(.system(size: 12, weight: .bold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(BuddyWidgetTheme.emeraldLive)
                        .frame(width: 6, height: 6)
                    Image(systemName: "dumbbell.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.leading, 2)
            } compactTrailing: {
                Text(context.attributes.sessionStartedAt, style: .timer)
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 58, alignment: .trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } minimal: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .keylineTint(.white.opacity(0.35))
            .widgetURL(DeepLink.session.url)
        }
    }
}

private struct WorkoutLiveActivityLockScreenView: View {
    let context: ActivityViewContext<WorkoutLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(BuddyWidgetTheme.emeraldLive)
                        .frame(width: 7, height: 7)
                    Text(context.state.sessionTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(BuddyWidgetTheme.emeraldLive)
                    Text(context.attributes.sessionStartedAt, style: .timer)
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 84, alignment: .trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }

            HStack(spacing: 8) {
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
                    label: "LIFTS",
                    value: "\(context.state.exerciseCount)"
                )
            }

            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        context.state.lastExerciseName.isEmpty
                            ? "Workout active"
                            : context.state.lastExerciseName
                    )
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                    Text(
                        context.state.lastSetDetail.isEmpty
                            ? "Tap Log Set to record by voice"
                            : context.state.lastSetDetail
                    )
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.65))
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Link(destination: DeepLink.record.url) {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 11.5, weight: .bold))
                        Text("Log Set")
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
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
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.55))
                .tracking(0.5)
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
#endif
