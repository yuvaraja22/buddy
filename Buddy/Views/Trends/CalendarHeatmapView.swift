import SwiftUI

struct CalendarHeatmapView: View {
    let days: [HeatmapDay]

    private let weekdayLabels: [String] = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        let weeks = buildWeekColumns()
        let activeDaysCount = days.filter { $0.setCount > 0 }.count

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(row == 1 || row == 3 || row == 5 ? weekdayLabels[row] : "")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .frame(width: 11, height: 14)
                    }
                }

                GeometryReader { proxy in
                    let columnCount = max(1, weeks.count)
                    let spacing: CGFloat = 4
                    let totalSpacing = spacing * CGFloat(max(0, columnCount - 1))
                    let cellSize = max(10, min(18, (proxy.size.width - totalSpacing) / CGFloat(columnCount)))

                    HStack(spacing: spacing) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 4) {
                                ForEach(0..<7, id: \.self) { row in
                                    if let day = week[row] {
                                        heatmapCell(for: day, size: cellSize)
                                    } else {
                                        Color.clear
                                            .frame(width: cellSize, height: 14)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(height: 7 * 14 + 6 * 4)
            }

            HStack(spacing: 6) {
                Text("\(activeDaysCount) active \(activeDaysCount == 1 ? "day" : "days") · Last 12 weeks")
                    .font(.caption2)
                    .buddyNumeric()
                    .foregroundStyle(.secondary)

                Spacer()

                HStack(spacing: 3) {
                    Text("Less")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)

                    ForEach(0...4, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(BuddyTheme.heatmapColor(for: level))
                            .frame(width: 10, height: 10)
                    }

                    Text("More")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func heatmapCell(for day: HeatmapDay, size: CGFloat) -> some View {
        let isToday = Calendar.current.isDateInToday(day.date)
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(BuddyTheme.heatmapColor(for: day.intensity))
            .frame(width: size, height: 14)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(BuddyTheme.cobalt, lineWidth: 1.25)
                }
            }
            .accessibilityLabel("\(day.date.formatted(date: .abbreviated, time: .omitted)): \(day.setCount) sets")
    }

    private func buildWeekColumns() -> [[HeatmapDay?]] {
        let sorted = days.sorted { $0.date < $1.date }
        guard !sorted.isEmpty else {
            return Array(repeating: Array(repeating: nil, count: 7), count: 12)
        }

        let calendar = Calendar.current
        var columns: [[HeatmapDay?]] = []
        var currentWeek: [HeatmapDay?] = Array(repeating: nil, count: 7)
        var currentWeekKey: DateComponents?

        for day in sorted {
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: day.date)
            if let activeKey = currentWeekKey, activeKey != comps {
                columns.append(currentWeek)
                currentWeek = Array(repeating: nil, count: 7)
            }
            currentWeekKey = comps
            let weekdayIndex = max(0, min(6, calendar.component(.weekday, from: day.date) - 1))
            currentWeek[weekdayIndex] = day
        }
        columns.append(currentWeek)

        if columns.count > 12 {
            return Array(columns.suffix(12))
        }
        return columns
    }
}
