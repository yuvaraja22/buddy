import SwiftUI
import Charts

private enum ExerciseChartMetric: String, CaseIterable, Identifiable {
    case topWeight = "Top Weight"
    case volume = "Volume"
    case reps = "Reps"

    var id: String { rawValue }
}

struct TrendsView: View {
    let store: WorkoutStore

    @State private var selectedTimeframe: TrendTimeframe = .month
    @State private var selectedExercise: String = ""
    @State private var selectedMetric: ExerciseChartMetric = .topWeight

    private static let timeframes: [TrendTimeframe] = [.week, .month, .threeMonths]

    var body: some View {
        let sessions = store.sessions
        let consistency = StatsCalculator.consistency(
            sessions: sessions,
            referenceDate: Date(),
            weeklyGoal: 4
        )
        let heatmapDays = StatsCalculator.heatmapDays(
            sessions: sessions,
            weeks: 12,
            referenceDate: Date()
        )
        let volumePoints = StatsCalculator.volumeSeries(
            sessions: sessions,
            timeframe: selectedTimeframe,
            referenceDate: Date()
        )
        let exerciseNames = StatsCalculator.loggedExerciseNames(sessions: sessions)
        let activeExercise = resolvedExerciseName(from: exerciseNames)
        let progressionPoints = activeExercise.map {
            StatsCalculator.exerciseProgression(canonicalName: $0, sessions: sessions)
        } ?? []
        let sortedHistory = sessions.sorted { $0.startedAt > $1.startedAt }

        NavigationStack {
            List {
                Section {
                    consistencyHeroCard(consistency: consistency, heatmapDays: heatmapDays)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    volumeTrendCard(points: volumePoints)
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    exerciseProgressionCard(
                        exerciseNames: exerciseNames,
                        activeExercise: activeExercise,
                        points: progressionPoints
                    )
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Section {
                    if sortedHistory.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "figure.strengthtraining.traditional")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No Workouts Yet")
                                    .font(.subheadline.weight(.semibold))
                                Text("Log your first set from the Workout tab to see full history and progression.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    } else {
                        ForEach(sortedHistory, id: \.id) { session in
                            NavigationLink {
                                SessionDetailView(session: session, store: store)
                            } label: {
                                sessionHistoryRow(session)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    BuddyHaptics.warning()
                                    store.deleteSession(session)
                                    WidgetRefreshHelper.sync(store: store)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Session History")
                        Spacer()
                        if !sortedHistory.isEmpty {
                            Text("\(sortedHistory.count)")
                                .buddyNumeric()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .navigationTitle("Trends")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    // MARK: - Consistency Hero Card

    private func consistencyHeroCard(
        consistency: ConsistencyStats,
        heatmapDays: [HeatmapDay]
    ) -> some View {
        NativeCard(padding: 16, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    Text("Consistency")
                        .font(.headline)
                    Spacer()
                    StatusPill(
                        text: "\(consistency.totalWorkouts) \(consistency.totalWorkouts == 1 ? "workout" : "workouts")",
                        tint: BuddyTheme.cobalt
                    )
                }

                HStack(spacing: 10) {
                    compactConsistencyMetric(
                        title: "Current Streak",
                        value: "\(consistency.currentStreakDays)d",
                        icon: "flame.fill",
                        tint: consistency.currentStreakDays > 0 ? BuddyTheme.amberStreak : .secondary
                    )
                    compactConsistencyMetric(
                        title: "Longest",
                        value: "\(consistency.longestStreakDays)d",
                        icon: "trophy.fill",
                        tint: BuddyTheme.cobalt
                    )
                    compactConsistencyMetric(
                        title: "This Week",
                        value: "\(consistency.workoutsThisWeek)/\(consistency.weeklyGoal)",
                        icon: "calendar",
                        tint: BuddyTheme.emeraldLive
                    )
                }

                Divider()
                    .overlay(BuddyTheme.hairlineBorder)

                CalendarHeatmapView(days: heatmapDays)
            }
        }
    }

    private func compactConsistencyMetric(
        title: String,
        value: String,
        icon: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
        )
    }

    // MARK: - Volume Trend Card

    private func volumeTrendCard(points: [VolumePoint]) -> some View {
        let totalVolumeKg = points.reduce(0.0) { $0 + $1.volumeKg }
        let totalSets = points.reduce(0) { $0 + $1.setCount }
        let hasVolume = points.contains { $0.volumeKg > 0 }

        return NativeCard(padding: 16, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume Trend")
                            .font(.headline)
                        Text("\(store.preferredUnit.formatVolume(kg: totalVolumeKg)) · \(totalSets) sets")
                            .font(.caption.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Picker("Timeframe", selection: $selectedTimeframe) {
                        ForEach(Self.timeframes, id: \.self) { timeframe in
                            Text(timeframeLabel(timeframe)).tag(timeframe)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 142)
                }

                if hasVolume {
                    Chart(points, id: \.id) { point in
                        BarMark(
                            x: .value("Period", point.label),
                            y: .value("Volume", store.preferredUnit.fromKg(point.volumeKg))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [BuddyTheme.cobalt, BuddyTheme.cobalt.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(6)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                            AxisValueLabel {
                                if let doubleVal = value.as(Double.self) {
                                    Text(shortAxisVolume(doubleVal))
                                        .font(.caption2)
                                        .buddyNumeric()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: volumeXAxisLabels(for: points)) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 185)
                } else {
                    emptyChartPlaceholder(
                        icon: "chart.bar.xaxis",
                        message: "Log weighted sets to see your \(timeframeLabel(selectedTimeframe)) training volume."
                    )
                }
            }
        }
    }

    // MARK: - Exercise Progression Card

    private func exerciseProgressionCard(
        exerciseNames: [String],
        activeExercise: String?,
        points: [ExerciseProgressPoint]
    ) -> some View {
        NativeCard(padding: 16, cornerRadius: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Exercise Progress")
                        .font(.headline)

                    Spacer(minLength: 8)

                    if let activeExercise, !exerciseNames.isEmpty {
                        Menu {
                            ForEach(exerciseNames, id: \.self) { name in
                                Button {
                                    BuddyHaptics.selection()
                                    selectedExercise = name
                                } label: {
                                    if name == activeExercise {
                                        Label(displayExerciseName(name), systemImage: "checkmark")
                                    } else {
                                        Text(displayExerciseName(name))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(displayExerciseName(activeExercise))
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .foregroundStyle(BuddyTheme.cobalt)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(BuddyTheme.cobaltSoft)
                            )
                        }
                    }
                }

                if !exerciseNames.isEmpty {
                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(ExerciseChartMetric.allCases) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                let hasNonZeroPoints = points.contains { metricValue(for: $0) > 0 }
                if !points.isEmpty && hasNonZeroPoints {
                    Chart(points, id: \.id) { point in
                        let value = metricValue(for: point)

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [BuddyTheme.cobalt.opacity(0.28), BuddyTheme.cobalt.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, value)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(BuddyTheme.cobalt)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, value)
                        )
                        .symbolSize(38)
                        .foregroundStyle(BuddyTheme.cobalt)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(Color.secondary.opacity(0.25))
                            AxisValueLabel {
                                if let doubleVal = value.as(Double.self) {
                                    Text(shortMetricLabel(doubleVal))
                                        .font(.caption2)
                                        .buddyNumeric()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(height: 185)
                } else {
                    emptyChartPlaceholder(
                        icon: "chart.xyaxis.line",
                        message: exerciseNames.isEmpty
                            ? "Log exercises across sessions to chart strength and volume gains."
                            : "No \(selectedMetric.rawValue.lowercased()) data recorded for \(displayExerciseName(activeExercise ?? "this exercise")) yet."
                    )
                }
            }
        }
    }

    // MARK: - Session History Row

    private func sessionHistoryRow(_ session: WorkoutSession) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(session.isActive ? BuddyTheme.emeraldLive.opacity(0.16) : BuddyTheme.cobaltSoft)
                    .frame(width: 40, height: 40)

                Image(systemName: session.sortedEntries.first?.muscleGroup.symbolName ?? "figure.strengthtraining.traditional")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(session.isActive ? BuddyTheme.emeraldLive : BuddyTheme.cobalt)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.derivedTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if session.isActive {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(BuddyTheme.emeraldLive)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(BuddyTheme.emeraldLive.opacity(0.15)))
                    }
                }

                Text("\(session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(DurationFormatter.formatCompact(seconds: session.durationSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(session.totalSets) sets")
                    .font(.caption.weight(.bold))
                    .buddyNumeric()
                    .foregroundStyle(.primary)

                if session.totalVolumeKg > 0 {
                    Text(store.preferredUnit.formatVolume(kg: session.totalVolumeKg))
                        .font(.caption2.weight(.medium))
                        .buddyNumeric()
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(session.totalReps) reps")
                        .font(.caption2.weight(.medium))
                        .buddyNumeric()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private func emptyChartPlaceholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.elevatedSurface.opacity(0.6))
        )
    }

    private func timeframeLabel(_ timeframe: TrendTimeframe) -> String {
        switch timeframe {
        case .week: return "1W"
        case .month: return "1M"
        case .threeMonths: return "3M"
        }
    }

    private func resolvedExerciseName(from names: [String]) -> String? {
        if !selectedExercise.isEmpty, names.contains(selectedExercise) {
            return selectedExercise
        }
        return names.first
    }

    private func displayExerciseName(_ name: String) -> String {
        if name == name.lowercased() {
            return name.capitalized
        }
        return name
    }

    private func metricValue(for point: ExerciseProgressPoint) -> Double {
        switch selectedMetric {
        case .topWeight:
            return store.preferredUnit.fromKg(point.maxWeightKg)
        case .volume:
            return store.preferredUnit.fromKg(point.totalVolumeKg)
        case .reps:
            return Double(point.totalReps)
        }
    }

    private func shortAxisVolume(_ value: Double) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", value / 1000.0)
        }
        return "\(Int(value.rounded()))"
    }

    private func shortMetricLabel(_ value: Double) -> String {
        switch selectedMetric {
        case .topWeight:
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? "\(Int(value)) \(store.preferredUnit.label)"
                : String(format: "%.1f", value)
        case .volume:
            return shortAxisVolume(value)
        case .reps:
            return "\(Int(value.rounded()))"
        }
    }

    private func volumeXAxisLabels(for points: [VolumePoint]) -> [String] {
        guard points.count > 7 else {
            return points.map(\.label)
        }
        let targetTicks = 5
        let lastIndex = points.count - 1
        var labels: [String] = []
        for step in 0..<targetTicks {
            let idx = Int((Double(step) * Double(lastIndex) / Double(targetTicks - 1)).rounded())
            let label = points[min(lastIndex, max(0, idx))].label
            if !labels.contains(label) {
                labels.append(label)
            }
        }
        return labels
    }
}
