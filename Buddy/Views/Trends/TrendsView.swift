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
    var dockClearance: CGFloat = 78

    @State private var selectedTimeframe: TrendTimeframe = .month
    @State private var selectedExercise: String = ""
    @State private var selectedMetric: ExerciseChartMetric = .topWeight

    private static let timeframes: [TrendTimeframe] = [.week, .month, .threeMonths]

    var body: some View {
        let sessions = store.sessions
        let consistency = StatsCalculator.consistency(
            sessions: sessions,
            referenceDate: Date(),
            weeklyGoal: store.weeklyGoal
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
        let sortedHistory = sessions
            .filter { $0.isActive || $0.countsAsWorkout }
            .sorted { $0.startedAt > $1.startedAt }

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    compactHeader(consistency: consistency)

                    consistencyHeroCard(consistency: consistency, heatmapDays: heatmapDays)

                    volumeTrendCard(points: volumePoints)

                    exerciseProgressionCard(
                        exerciseNames: exerciseNames,
                        activeExercise: activeExercise,
                        points: progressionPoints
                    )

                    historySection(sortedHistory: sortedHistory)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, max(BuddyTheme.floatingBarClearance, dockClearance + 24))
            }
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Compact Header

    private func compactHeader(consistency: ConsistencyStats) -> some View {
        HStack(alignment: .center) {
            Text("Trends")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            StatusPill(
                text: "\(consistency.totalWorkouts) \(consistency.totalWorkouts == 1 ? "workout" : "workouts")",
                tint: BuddyTheme.inkPrimary
            )
        }
        .padding(.top, 2)
    }

    // MARK: - Consistency & Monochrome Heatmap

    private func consistencyHeroCard(
        consistency: ConsistencyStats,
        heatmapDays: [HeatmapDay]
    ) -> some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Consistency")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    compactConsistencyMetric(
                        title: "Streak",
                        value: "\(consistency.currentStreakDays)d",
                        icon: "flame.fill",
                        tint: consistency.currentStreakDays > 0 ? BuddyTheme.amberStreak : BuddyTheme.mutedText
                    )
                    compactConsistencyMetric(
                        title: "Best",
                        value: "\(consistency.longestStreakDays)d",
                        icon: "trophy.fill",
                        tint: BuddyTheme.inkPrimary
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
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(value)
                .font(.system(size: 19, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
        )
    }

    // MARK: - Volume Trend Card (YouTube Chips + Crisp Monochrome Bars)

    private func volumeTrendCard(points: [VolumePoint]) -> some View {
        let totalVolumeKg = points.reduce(0.0) { $0 + $1.volumeKg }
        let totalSets = points.reduce(0) { $0 + $1.setCount }
        let hasVolume = points.contains { $0.volumeKg > 0 }

        return NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Volume")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                        Text("\(store.preferredUnit.formatVolume(kg: totalVolumeKg)) · \(totalSets) sets")
                            .font(.caption.weight(.semibold))
                            .buddyNumeric()
                            .foregroundStyle(BuddyTheme.mutedText)
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 6) {
                        ForEach(Self.timeframes, id: \.self) { timeframe in
                            FilterChip(
                                title: timeframeLabel(timeframe),
                                isSelected: selectedTimeframe == timeframe
                            ) {
                                selectedTimeframe = timeframe
                            }
                        }
                    }
                }

                if hasVolume {
                    Chart(points, id: \.id) { point in
                        BarMark(
                            x: .value("Period", point.label),
                            y: .value("Volume", store.preferredUnit.fromKg(point.volumeKg))
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [BuddyTheme.inkPrimary, BuddyTheme.inkPrimary.opacity(0.45)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .cornerRadius(5)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(BuddyTheme.hairlineBorder)
                            AxisValueLabel {
                                if let doubleVal = value.as(Double.self) {
                                    Text(shortAxisVolume(doubleVal))
                                        .font(.caption2)
                                        .buddyNumeric()
                                        .foregroundStyle(BuddyTheme.mutedText)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: volumeXAxisLabels(for: points)) { _ in
                            AxisValueLabel()
                                .font(.caption2)
                                .foregroundStyle(BuddyTheme.mutedText)
                        }
                    }
                    .frame(height: 180)
                } else {
                    emptyChartPlaceholder(
                        icon: "chart.bar.xaxis",
                        message: "Log weighted sets to see your \(timeframeLabel(selectedTimeframe)) training volume."
                    )
                }
            }
        }
    }

    // MARK: - Exercise Progression Card (YouTube Exercise Chips + Crisp White Line)

    private func exerciseProgressionCard(
        exerciseNames: [String],
        activeExercise: String?,
        points: [ExerciseProgressPoint]
    ) -> some View {
        NativeCard(padding: 15, cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Exercise Progress")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)

                if !exerciseNames.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(exerciseNames, id: \.self) { name in
                                FilterChip(
                                    title: displayExerciseName(name),
                                    isSelected: name == activeExercise
                                ) {
                                    selectedExercise = name
                                }
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(ExerciseChartMetric.allCases) { metric in
                            let isSelected = (selectedMetric == metric)
                            Button {
                                BuddyHaptics.selection()
                                selectedMetric = metric
                            } label: {
                                Text(metric.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isSelected ? BuddyTheme.inkInverse : BuddyTheme.mutedText)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.elevatedSurface)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                let hasNonZeroPoints = points.contains { metricValue(for: $0) > 0 }
                if !points.isEmpty && hasNonZeroPoints {
                    let allSameDay: Bool = {
                        guard let first = points.first?.date else { return false }
                        return points.allSatisfy { Calendar.current.isDate($0.date, inSameDayAs: first) }
                    }()
                    let xTickDates: [Date] = {
                        if points.count <= 4 {
                            return points.map(\.date)
                        }
                        let step = max(1, (points.count - 1) / 3)
                        var selected: [Date] = []
                        var idx = 0
                        while idx < points.count {
                            selected.append(points[idx].date)
                            idx += step
                        }
                        if let last = points.last?.date, selected.last != last {
                            selected.append(last)
                        }
                        return selected
                    }()

                    Chart(points, id: \.id) { point in
                        let value = metricValue(for: point)

                        if points.count >= 2 {
                            AreaMark(
                                x: .value("Date", point.date),
                                y: .value(selectedMetric.rawValue, value)
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [BuddyTheme.inkPrimary.opacity(0.22), BuddyTheme.inkPrimary.opacity(0.01)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                            LineMark(
                                x: .value("Date", point.date),
                                y: .value(selectedMetric.rawValue, value)
                            )
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(BuddyTheme.inkPrimary)
                        }

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, value)
                        )
                        .symbolSize(points.count == 1 ? 60 : 34)
                        .foregroundStyle(BuddyTheme.inkPrimary)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                                .foregroundStyle(BuddyTheme.hairlineBorder)
                            AxisValueLabel {
                                if let doubleVal = value.as(Double.self) {
                                    Text(shortMetricLabel(doubleVal))
                                        .font(.caption2)
                                        .buddyNumeric()
                                        .foregroundStyle(BuddyTheme.mutedText)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: xTickDates) { _ in
                            if allSameDay && points.count > 1 {
                                AxisValueLabel(format: .dateTime.hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(BuddyTheme.mutedText)
                            } else {
                                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                                    .foregroundStyle(BuddyTheme.mutedText)
                            }
                        }
                    }
                    .frame(height: 180)
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

    // MARK: - YouTube-Style Session History Feed

    private func historySection(sortedHistory: [WorkoutSession]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("History")
                    .font(BuddyTheme.sectionTitleFont)
                    .foregroundStyle(.primary)
                Spacer()
                if !sortedHistory.isEmpty {
                    Text("\(sortedHistory.count)")
                        .font(.caption.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(BuddyTheme.mutedText)
                }
            }

            if sortedHistory.isEmpty {
                NativeCard(padding: 16, cornerRadius: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.title3)
                            .foregroundStyle(BuddyTheme.mutedText)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No Workouts Yet")
                                .font(.subheadline.weight(.bold))
                            Text("Log your first set from Home to see full history and progression.")
                                .font(.caption)
                                .foregroundStyle(BuddyTheme.mutedText)
                        }
                    }
                }
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(sortedHistory, id: \.id) { session in
                        HStack(alignment: .top, spacing: 8) {
                            NavigationLink {
                                SessionDetailView(session: session, store: store)
                            } label: {
                                sessionHistoryRow(session)
                            }
                            .buttonStyle(.plain)

                            Menu {
                                Button(role: .destructive) {
                                    BuddyHaptics.warning()
                                    store.deleteSession(session)
                                    WidgetRefreshHelper.sync(store: store)
                                } label: {
                                    Label("Delete Session", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(BuddyTheme.mutedText)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Session options")
                        }
                    }
                }
            }
        }
    }

    private func sessionHistoryRow(_ session: WorkoutSession) -> some View {
        let isCheckInOnly = (session.totalSets == 0 && session.isManualCheckInDay)
        let badgeText = isCheckInOnly
            ? "Check-in"
            : DurationFormatter.formatClock(seconds: max(1, session.durationSeconds))

        return HStack(alignment: .top, spacing: 12) {
            WorkoutThumbnailView(
                assetName: session.primaryMuscleGroup.thumbnailAssetName,
                bottomRightBadge: badgeText,
                topLeftTag: session.isActive ? "LIVE" : nil,
                isLiveTag: session.isActive,
                width: 128,
                height: 74
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(session.derivedTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(
                    isCheckInOnly
                        ? session.startedAt.formatted(date: .abbreviated, time: .omitted)
                        : session.startedAt.formatted(date: .abbreviated, time: .shortened)
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BuddyTheme.mutedText)
                .lineLimit(1)

                if isCheckInOnly {
                    Text(session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Marked as trained" : session.notes)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BuddyTheme.emeraldLive)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 5) {
                        Text("\(session.totalSets) sets")
                            .monospacedDigit()
                        Text("·")
                        if session.totalVolumeKg > 0 {
                            Text(store.preferredUnit.formatVolume(kg: session.totalVolumeKg))
                                .monospacedDigit()
                        } else {
                            Text("\(session.totalReps) reps")
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(BuddyTheme.mutedText)
                    .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }

    // MARK: - Helpers

    private func emptyChartPlaceholder(icon: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(BuddyTheme.mutedText)
            Text(message)
                .font(.caption)
                .foregroundStyle(BuddyTheme.mutedText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 136)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BuddyTheme.elevatedSurface)
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
