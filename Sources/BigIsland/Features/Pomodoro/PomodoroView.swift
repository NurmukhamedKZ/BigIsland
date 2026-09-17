import SwiftUI

// Один акцент на всё приложение: учёба — синий, отдых — нейтральный светлый.
private let studyColor = Theme.accent
private let restColor = Theme.muted

struct PomodoroView: View {
    @ObservedObject var feature: PomodoroFeature

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            TimerPanel(feature: feature)
                .frame(width: 220)
            Rectangle().fill(Theme.hairline).frame(width: 1)
            StudyCalendar(days: feature.days)
        }
    }
}

// MARK: - Секундомер

private struct TimerPanel: View {
    @ObservedObject var feature: PomodoroFeature

    var body: some View {
        let session = feature.session
        let accent = session.phase == .rest ? restColor : studyColor

        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = session.phase == .idle ? 0 : context.date.timeIntervalSince(session.phaseStart)
            let reached = feature.target.map { elapsed >= $0 } ?? false

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title(session))
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(-0.12)
                        .foregroundStyle(session.phase == .idle ? Theme.muted : accent)
                    Spacer()
                    RoundDots(completed: session.completed, studying: session.phase == .study)
                }

                Text(clock(elapsed))
                    .font(.system(size: 44, weight: .semibold))
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(reached ? accent : .white)

                if let target = feature.target {
                    ProgressView(value: min(elapsed / target, 1))
                        .tint(accent)
                        .controlSize(.small)
                }

                HStack(spacing: 10) {
                    switch session.phase {
                    case .idle, .rest:
                        PillButton(title: "Учиться", icon: "play.fill", primary: true, action: feature.startStudy)
                    case .study:
                        PillButton(title: "Отдых", icon: "cup.and.saucer.fill", primary: false, action: feature.finishStudy)
                    }
                    if session.phase != .idle {
                        Button(action: feature.reset) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PressStyle())
                        .help("Сбросить цикл")
                    }
                }

                Spacer(minLength: 0)

                let key = PomodoroFeature.dayKey(context.date, calendar: .current)
                HStack(spacing: 4) {
                    Text("Сегодня").foregroundStyle(Theme.muted)
                    Text(duration(feature.studied(on: key, now: context.date)))
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                }
                .font(.system(size: 14))
                .tracking(-0.224)
            }
        }
    }

    private func title(_ session: PomodoroFeature.Session) -> String {
        switch session.phase {
        case .idle: "Готов к учёбе"
        case .study: "Учёба · круг \(session.completed + 1)/\(PomodoroFeature.roundsPerCycle)"
        case .rest: session.completed >= PomodoroFeature.roundsPerCycle ? "Большой отдых" : "Отдых"
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

private struct RoundDots: View {
    let completed: Int
    let studying: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<PomodoroFeature.roundsPerCycle, id: \.self) { i in
                Circle()
                    .strokeBorder(studyColor, lineWidth: 1.5)
                    .background(Circle().fill(i < completed ? studyColor : .clear))
                    .opacity(i < completed || (studying && i == completed) ? 1 : 0.3)
                    .frame(width: 8, height: 8)
            }
        }
    }
}

/// Основная — синяя капсула с белым текстом, вторичная — контурная капсула.
private struct PillButton: View {
    let title: String
    let icon: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 14))
                .tracking(-0.224)
                .foregroundStyle(primary ? .white : Theme.accent)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Capsule().fill(primary ? Theme.action : .clear))
                .overlay(Capsule().strokeBorder(primary ? .clear : Theme.accent, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
    }
}

/// «2ч 15м», «45м»
private func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    return m >= 60 ? "\(m / 60)ч \(m % 60)м" : "\(m)м"
}

// MARK: - Календарь месяца

private struct StudyCalendar: View {
    let days: [String: TimeInterval]
    @State private var month = Date()

    private static let calendar: Calendar = {
        var c = Calendar(identifier: .iso8601) // неделя с понедельника, ISO-номера недель
        c.timeZone = .current
        return c
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL"
        return f
    }()

    var body: some View {
        let cal = Self.calendar
        let first = cal.date(from: cal.dateComponents([.year, .month], from: month))!
        let gridStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: first))!
        let dates = (0..<42).map { cal.date(byAdding: .day, value: $0, to: gridStart)! }
        let monthTotal = dates.filter { cal.isDate($0, equalTo: first, toGranularity: .month) }
            .reduce(0) { $0 + (days[PomodoroFeature.dayKey($1, calendar: cal)] ?? 0) }

        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Self.monthFormatter.string(from: first).capitalized) \(String(cal.component(.year, from: first)))")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.374)
                Text(duration(monthTotal))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
                Spacer()
                navButton("chevron.left") { shift(-1) }
                Button { month = Date() } label: {
                    Text("Сегодня").font(.system(size: 12)).tracking(-0.12)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(PressStyle())
                navButton("chevron.right") { shift(1) }
            }

            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(["Н", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity)
                    }
                }
                Rectangle().fill(Theme.hairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)

                ForEach(0..<6, id: \.self) { row in
                    GridRow {
                        let week = dates[row * 7]
                        Text(String(cal.component(.weekOfYear, from: week)))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Theme.faint)
                        ForEach(0..<7, id: \.self) { col in
                            dayCell(dates[row * 7 + col], month: first)
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func dayCell(_ date: Date, month: Date) -> some View {
        let cal = Self.calendar
        let seconds = days[PomodoroFeature.dayKey(date, calendar: cal)] ?? 0
        let studied = seconds >= 60
        let isToday = cal.isDateInToday(date)
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)

        // Есть учёба — показываем время, иначе тусклый номер дня для ориентира.
        return Text(studied ? compact(seconds) : String(cal.component(.day, from: date)))
            .font(.system(size: studied ? 10 : 11, weight: studied ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(studied ? Theme.accent : Theme.faint)
            .frame(maxWidth: .infinity, minHeight: 25)
            .background(shape.fill(studied ? Theme.tile : .clear))
            .overlay(shape.strokeBorder(isToday ? Theme.accent : .clear, lineWidth: 2))
            .opacity(cal.isDate(date, equalTo: month, toGranularity: .month) ? 1 : 0.35)
    }

    /// «2ч15м», «45м» — влезает в узкую ячейку.
    private func compact(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        return m >= 60 ? "\(m / 60)ч\(String(format: "%02d", m % 60))м" : "\(m)м"
    }

    private func shift(_ months: Int) {
        month = Self.calendar.date(byAdding: .month, value: months, to: month)!
    }

    private func navButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PressStyle())
    }
}
