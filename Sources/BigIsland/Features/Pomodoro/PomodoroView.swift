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
            StudyCalendar(feature: feature)
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

/// «2ч 15м», «45м»
private func duration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60
    return m >= 60 ? "\(m / 60)ч \(m % 60)м" : "\(m)м"
}

// MARK: - Календарь месяца

private struct StudyCalendar: View {
    @ObservedObject var feature: PomodoroFeature
    @State private var month = Date()
    /// День, для которого открыта ручная правка (двойной клик по ячейке).
    @State private var editing: Date?
    @State private var hours = ""
    @State private var minutes = ""
    @FocusState private var hoursFocused: Bool

    private var days: [String: TimeInterval] { feature.days }

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

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMMM"
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
            if let editing {
                editor(editing)
            } else {
                header(first: first, monthTotal: monthTotal)
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

    private func header(first: Date, monthTotal: TimeInterval) -> some View {
        let cal = Self.calendar
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
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
    }

    /// Ручной ввод учёбы за день: часы + минуты, Enter — сохранить, Esc — отмена.
    private func editor(_ date: Date) -> some View {
        HStack(spacing: 6) {
            Text(Self.dayFormatter.string(from: date))
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.374)
            Spacer()
            field($hours, unit: "ч").focused($hoursFocused)
            field($minutes, unit: "м")
            navButton("checkmark") { commit(date) }
            navButton("xmark") { editing = nil }
        }
        .onExitCommand { editing = nil }
    }

    private func field(_ text: Binding<String>, unit: String) -> some View {
        HStack(spacing: 2) {
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 24)
                .onSubmit { if let editing { commit(editing) } }
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.tile))
    }

    private func beginEdit(_ date: Date) {
        let m = Int(feature.studied(on: PomodoroFeature.dayKey(date, calendar: Self.calendar))) / 60
        hours = String(m / 60)
        minutes = String(m % 60)
        editing = date
        NSApp.currentEvent?.window?.makeKey() // иначе клавиатура не дойдёт до панели
        hoursFocused = true
    }

    private func commit(_ date: Date) {
        let h = Int(hours.trimmingCharacters(in: .whitespaces)) ?? 0
        let m = Int(minutes.trimmingCharacters(in: .whitespaces)) ?? 0
        let seconds = TimeInterval(min(max(h * 60 + m, 0), 24 * 60) * 60) // не больше суток
        feature.setStudied(seconds, on: PomodoroFeature.dayKey(date, calendar: Self.calendar))
        editing = nil
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
            .overlay(shape.strokeBorder(editing.map { cal.isDate($0, inSameDayAs: date) } == true ? .white : .clear, lineWidth: 1))
            .opacity(cal.isDate(date, equalTo: month, toGranularity: .month) ? 1 : 0.35)
            .contentShape(shape)
            .onTapGesture(count: 2) { beginEdit(date) }
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
