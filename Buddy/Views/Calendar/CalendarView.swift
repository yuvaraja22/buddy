import SwiftUI

/// Interactive OLED monochrome monthly workout calendar.
/// Lets users track training history across months, 1-tap mark/unmark any current or past day
/// as trained (counting toward streaks & goals), and manually or voice-log full exercises on any date.
struct CalendarView: View {
    let store: WorkoutStore
    var dockClearance: CGFloat = 78
    let onVoiceLogDate: (Date) -> Void

    @State private var displayedMonth: Date
    @State private var selectedDate: Date
    @State private var selectedSplitTag: String = "Push Day"
    @State private var checkInNote: String = ""
    @State private var showManualAddForSelectedDate: Bool = false

    private let weekdaySymbols: [String] = ["S", "M", "T", "W", "T", "F", "S"]
    private let splitOptions: [(label: String, title: String)] = [
        ("Push", "Push Day"),
        ("Pull", "Pull Day"),
        ("Legs", "Leg Day"),
        ("Upper", "Upper Body"),
        ("Lower", "Lower Body"),
        ("Cardio", "Cardio"),
        ("Gym", "Workout")
    ]

    private let gridColumns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    init(
        store: WorkoutStore,
        dockClearance: CGFloat = 78,
        onVoiceLogDate: @escaping (Date) -> Void
    ) {
        self.store = store
        self.dockClearance = dockClearance
        self.onVoiceLogDate = onVoiceLogDate

        let today = Calendar.current.startOfDay(for: Date())
        _selectedDate = State(initialValue: today)
        _displayedMonth = State(initialValue: Self.startOfMonth(for: today))
    }

    private var gregorianCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        cal.firstWeekday = 1
        return cal
    }

    private var todayStart: Date {
        gregorianCalendar.startOfDay(for: Date())
    }

    private var isViewingCurrentMonth: Bool {
        gregorianCalendar.isDate(displayedMonth, equalTo: todayStart, toGranularity: .month)
    }

    private var canAdvanceMonth: Bool {
        !isViewingCurrentMonth
    }

    var body: some View {
        let cal = gregorianCalendar
        let consistency = StatsCalculator.consistency(sessions: store.sessions, referenceDate: Date(), weeklyGoal: store.weeklyGoal)
        let monthSummary = buildMonthSummary(for: displayedMonth, calendar: cal)
        let daySessions = store.sessions(on: selectedDate, calendar: cal)
        let sessionsByDay = buildSessionsByDayMap(calendar: cal)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    compactHeader(consistency: consistency)

                    monthStatsStrip(summary: monthSummary, consistency: consistency)

                    monthGridCard(
                        month: displayedMonth,
                        calendar: cal,
                        sessionsByDay: sessionsByDay
                    )

                    selectedDaySection(
                        date: selectedDate,
                        sessions: daySessions,
                        calendar: cal
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, max(BuddyTheme.floatingBarClearance, dockClearance + 24))
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BuddyTheme.canvasBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showManualAddForSelectedDate) {
                ManualAddExerciseSheet(store: store, targetDate: selectedDate)
                    .buddyAppearance()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    // MARK: - Header

    private func compactHeader(consistency: ConsistencyStats) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Calendar")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.primary)

            Spacer()

            if !isViewingCurrentMonth || !gregorianCalendar.isDateInToday(selectedDate) {
                Button {
                    BuddyHaptics.selection()
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedDate = todayStart
                        displayedMonth = Self.startOfMonth(for: todayStart)
                    }
                } label: {
                    Text("Today")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(BuddyTheme.inkInverse)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(BuddyTheme.inkPrimary))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(consistency.currentStreakDays > 0 ? BuddyTheme.amberStreak : BuddyTheme.mutedText)
                Text("\(consistency.currentStreakDays)d")
                    .font(.system(size: 12.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(BuddyTheme.cardSurface))
            .overlay {
                Capsule().strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Monthly Micro Stats Strip

    private struct MonthSummary {
        let activeDays: Int
        let totalSets: Int
        let checkInDays: Int
    }

    private func monthStatsStrip(summary: MonthSummary, consistency: ConsistencyStats) -> some View {
        HStack(spacing: 0) {
            stripCell(title: "DAYS", value: "\(summary.activeDays)")
            stripDivider
            stripCell(title: "SETS", value: "\(summary.totalSets)")
            stripDivider
            stripCell(title: "THIS WEEK", value: "\(consistency.workoutsThisWeek)/\(consistency.weeklyGoal)")
            stripDivider
            stripCell(title: "BEST", value: "\(consistency.longestStreakDays)d")
        }
        .padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
        }
    }

    private func stripCell(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(BuddyTheme.mutedText)
        }
        .frame(maxWidth: .infinity)
    }

    private var stripDivider: some View {
        Rectangle()
            .fill(BuddyTheme.hairlineBorder)
            .frame(width: 0.75, height: 24)
    }

    // MARK: - Interactive Month Grid Card

    private func monthGridCard(
        month: Date,
        calendar: Calendar,
        sessionsByDay: [Date: [WorkoutSession]]
    ) -> some View {
        let cells = buildMonthCells(for: month, calendar: calendar)

        return NativeCard(padding: 14, cornerRadius: 16) {
            VStack(spacing: 14) {
                // Month navigation header
                HStack {
                    Button {
                        shiftMonth(by: -1, calendar: calendar)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(BuddyTheme.elevatedSurface))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")

                    Spacer()

                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.primary)

                    Spacer()

                    Button {
                        shiftMonth(by: 1, calendar: calendar)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(canAdvanceMonth ? Color.primary : BuddyTheme.mutedText.opacity(0.4))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(BuddyTheme.elevatedSurface))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdvanceMonth)
                    .accessibilityLabel("Next month")
                }

                // Weekday headers (Sunday-first)
                LazyVGrid(columns: gridColumns, spacing: 4) {
                    ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(BuddyTheme.mutedText)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Day cells
                LazyVGrid(columns: gridColumns, spacing: 8) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, maybeDate in
                        if let dayDate = maybeDate {
                            dayCell(
                                date: dayDate,
                                calendar: calendar,
                                sessions: sessionsByDay[dayDate] ?? []
                            )
                        } else {
                            Color.clear
                                .frame(height: 44)
                        }
                    }
                }

                // Compact legend
                HStack(spacing: 14) {
                    legendItem(color: BuddyTheme.inkPrimary, isRing: false, label: "Logged sets")
                    legendItem(color: BuddyTheme.emeraldLive, isRing: true, label: "Marked day")
                    Spacer()
                    Text("Tap any day")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(BuddyTheme.mutedText)
                }
                .padding(.top, 2)
            }
        }
    }

    private func dayCell(
        date: Date,
        calendar: Calendar,
        sessions: [WorkoutSession]
    ) -> some View {
        let isToday = calendar.isDate(date, inSameDayAs: todayStart)
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let isFuture = date > todayStart
        let hasLoggedSets = sessions.contains { $0.totalSets > 0 }
        let hasCheckInOnly = !hasLoggedSets && sessions.contains { $0.isManualCheckInDay }
        let dayNumber = calendar.component(.day, from: date)

        return Button {
            guard !isFuture else { return }
            BuddyHaptics.selection()
            selectedDate = date
            checkInNote = ""
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    if hasLoggedSets {
                        Circle()
                            .fill(BuddyTheme.inkPrimary)
                            .frame(width: 34, height: 34)
                    } else if hasCheckInOnly {
                        Circle()
                            .fill(BuddyTheme.emeraldLive.opacity(0.16))
                            .frame(width: 34, height: 34)
                            .overlay {
                                Circle()
                                    .strokeBorder(BuddyTheme.emeraldLive, lineWidth: 1.5)
                            }
                    } else if isSelected {
                        Circle()
                            .fill(BuddyTheme.elevatedSurface)
                            .frame(width: 34, height: 34)
                    }

                    Text("\(dayNumber)")
                        .font(.system(size: 13.5, weight: (hasLoggedSets || isSelected || isToday) ? .bold : .medium))
                        .monospacedDigit()
                        .foregroundStyle(
                            hasLoggedSets
                                ? BuddyTheme.inkInverse
                                : (isFuture ? BuddyTheme.mutedText.opacity(0.32) : Color.primary)
                        )
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(BuddyTheme.inkPrimary, lineWidth: 1.8)
                            .frame(width: 39, height: 39)
                    } else if isToday && !hasLoggedSets && !hasCheckInOnly {
                        Circle()
                            .strokeBorder(BuddyTheme.mutedText.opacity(0.55), lineWidth: 1.1)
                            .frame(width: 34, height: 34)
                    }
                }

                // Bottom indicator dot
                Circle()
                    .fill(
                        hasCheckInOnly
                            ? BuddyTheme.emeraldLive
                            : (isToday ? BuddyTheme.inkPrimary : Color.clear)
                    )
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(accessibilityLabelForDay(date: date, hasLoggedSets: hasLoggedSets, hasCheckInOnly: hasCheckInOnly))
    }

    private func legendItem(color: Color, isRing: Bool, label: String) -> some View {
        HStack(spacing: 5) {
            if isRing {
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                    .background(Circle().fill(color.opacity(0.16)))
                    .frame(width: 9, height: 9)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BuddyTheme.mutedText)
        }
    }

    // MARK: - Selected Day Detail & Check-In Panel

    private func selectedDaySection(
        date: Date,
        sessions: [WorkoutSession],
        calendar: Calendar
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(BuddyTheme.sectionTitleFont)
                    .foregroundStyle(Color.primary)

                if let badge = relativeDayBadge(for: date, calendar: calendar) {
                    StatusPill(text: badge, tint: BuddyTheme.inkPrimary)
                }

                Spacer()
            }

            if !sessions.isEmpty {
                VStack(spacing: 10) {
                    ForEach(sessions, id: \.id) { session in
                        if session.totalSets == 0 && session.isManualCheckInDay {
                            manualCheckInCard(session)
                        } else {
                            loggedSessionCard(session)
                        }
                    }
                }

                // Add more exercises or voice-log onto this same day
                dayLogActionRow(date: date)
            } else {
                // Quick 1-Tap Check-In Card
                NativeCard(padding: 14, cornerRadius: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quick Check-In")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                Text("Mark this day as trained to keep your streak & calendar complete.")
                                    .font(.caption)
                                    .foregroundStyle(BuddyTheme.mutedText)
                            }
                            Spacer()
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(splitOptions, id: \.title) { option in
                                    let isSelected = (selectedSplitTag == option.title)
                                    Button {
                                        BuddyHaptics.selection()
                                        selectedSplitTag = option.title
                                    } label: {
                                        Text(option.label)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(isSelected ? BuddyTheme.inkInverse : Color.primary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(
                                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(isSelected ? BuddyTheme.inkPrimary : BuddyTheme.chipSurface)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        TextField("Optional note (e.g. 45m gym, felt strong)", text: $checkInNote)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(BuddyTheme.elevatedSurface)
                            )

                        Button {
                            BuddyHaptics.success()
                            _ = store.markDayAsTrained(
                                on: date,
                                title: selectedSplitTag,
                                notes: checkInNote
                            )
                            checkInNote = ""
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Mark as Trained · \(selectedSplitTag)")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(BuddyTheme.inkInverse)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(BuddyTheme.inkPrimary))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Or log full exercises on this date via voice or manual entry
                dayLogActionRow(date: date)
            }
        }
    }

    private func manualCheckInCard(_ session: WorkoutSession) -> some View {
        NativeCard(padding: 14, cornerRadius: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(BuddyTheme.emeraldLive.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(BuddyTheme.emeraldLive)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.derivedTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.primary)

                    if !session.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(session.notes)
                            .font(.caption)
                            .foregroundStyle(BuddyTheme.mutedText)
                            .lineLimit(2)
                    } else {
                        Text("Marked as trained")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(BuddyTheme.mutedText)
                    }
                }

                Spacer(minLength: 6)

                Button {
                    BuddyHaptics.warning()
                    store.deleteSession(session)
                    WidgetRefreshHelper.sync(store: store)
                } label: {
                    Text("Unmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BuddyTheme.destructive)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(BuddyTheme.destructive.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func loggedSessionCard(_ session: WorkoutSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            NavigationLink {
                SessionDetailView(session: session, store: store)
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    WorkoutThumbnailView(
                        assetName: session.primaryMuscleGroup.thumbnailAssetName,
                        bottomRightBadge: session.durationSeconds > 0
                            ? DurationFormatter.formatClock(seconds: session.durationSeconds)
                            : "\(session.totalSets) sets",
                        topLeftTag: session.isActive ? "LIVE" : nil,
                        isLiveTag: session.isActive,
                        width: 118,
                        height: 68
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.derivedTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)

                        Text("\(session.exerciseCount) \(session.exerciseCount == 1 ? "exercise" : "exercises") · \(session.totalSets) sets · \(session.totalReps) reps")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(BuddyTheme.mutedText)
                            .lineLimit(1)

                        let exercisePreview = session.sortedEntries.prefix(3).map(\.exerciseName).joined(separator: ", ")
                        if !exercisePreview.isEmpty {
                            Text(exercisePreview)
                                .font(.caption)
                                .foregroundStyle(BuddyTheme.mutedText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(role: .destructive) {
                    BuddyHaptics.warning()
                    store.deleteSession(session)
                    WidgetRefreshHelper.sync(store: store)
                } label: {
                    Label("Delete Workout", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(BuddyTheme.mutedText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Workout options")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(BuddyTheme.cardSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
        }
    }

    private func dayLogActionRow(date: Date) -> some View {
        HStack(spacing: 10) {
            Button {
                BuddyHaptics.mediumImpact()
                onVoiceLogDate(date)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 12.5, weight: .bold))
                    Text("Voice Log Day")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BuddyTheme.cardSurface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
                }
            }
            .buttonStyle(.plain)

            Button {
                BuddyHaptics.lightImpact()
                showManualAddForSelectedDate = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12.5, weight: .bold))
                    Text("Add Exercise")
                        .font(.system(size: 13.5, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(BuddyTheme.cardSurface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(BuddyTheme.hairlineBorder, lineWidth: 0.85)
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Calendar Date Helpers

    private static func startOfMonth(for date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Calendar.current.timeZone
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? cal.startOfDay(for: date)
    }

    private func shiftMonth(by delta: Int, calendar: Calendar) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        let normalizedNext = Self.startOfMonth(for: next)
        let currentMonthStart = Self.startOfMonth(for: todayStart)
        guard normalizedNext <= currentMonthStart else { return }

        BuddyHaptics.selection()
        withAnimation(.snappy(duration: 0.2)) {
            displayedMonth = normalizedNext
            if calendar.isDate(normalizedNext, equalTo: todayStart, toGranularity: .month) {
                selectedDate = todayStart
            } else {
                selectedDate = normalizedNext
            }
        }
    }

    private func buildMonthCells(for monthStart: Date, calendar: Calendar) -> [Date?] {
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else {
            return []
        }
        let firstWeekday = calendar.component(.weekday, from: monthStart) // 1 = Sun ... 7 = Sat
        let leadingBlanks = max(0, firstWeekday - 1)

        var cells: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for dayOffset in 0..<dayRange.count {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) {
                cells.append(calendar.startOfDay(for: date))
            }
        }
        return cells
    }

    private func buildSessionsByDayMap(calendar: Calendar) -> [Date: [WorkoutSession]] {
        var map: [Date: [WorkoutSession]] = [:]
        for session in store.sessions where session.isActive || session.countsAsWorkout {
            let day = calendar.startOfDay(for: session.startedAt)
            map[day, default: []].append(session)
        }
        return map
    }

    private func buildMonthSummary(for monthStart: Date, calendar: Calendar) -> MonthSummary {
        let monthSessions = store.sessions.filter { session in
            session.countsAsWorkout && calendar.isDate(session.startedAt, equalTo: monthStart, toGranularity: .month)
        }
        let activeDays = Set(monthSessions.map { calendar.startOfDay(for: $0.startedAt) }).count
        let totalSets = monthSessions.reduce(0) { $0 + $1.totalSets }
        let checkInDays = Set(
            monthSessions
                .filter { $0.isManualCheckInDay && $0.totalSets == 0 }
                .map { calendar.startOfDay(for: $0.startedAt) }
        ).count
        return MonthSummary(activeDays: activeDays, totalSets: totalSets, checkInDays: checkInDays)
    }

    private func relativeDayBadge(for date: Date, calendar: Calendar) -> String? {
        if calendar.isDate(date, inSameDayAs: todayStart) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let daysAgo = calendar.dateComponents([.day], from: date, to: todayStart).day ?? 0
        if daysAgo > 1 {
            return "\(daysAgo)d ago"
        }
        return nil
    }

    private func accessibilityLabelForDay(date: Date, hasLoggedSets: Bool, hasCheckInOnly: Bool) -> String {
        let label = date.formatted(date: .abbreviated, time: .omitted)
        if hasLoggedSets { return "\(label), workout logged" }
        if hasCheckInOnly { return "\(label), marked as trained" }
        return label
    }
}
