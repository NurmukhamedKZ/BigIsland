import AppKit
import SwiftUI

/// Помодоро-секундомер: учёба 50 мин → отдых 10 мин, ×4, потом отдых 30 мин.
/// Фазы не переключаются сами: учёба идёт, пока её не закончишь; отдых — пока не начнёшь учёбу.
/// На цели (50 / 10 / 30 мин) звучит звук, счёт продолжается.
/// Время учёбы по дням хранится навсегда в Application Support.
@MainActor
final class PomodoroFeature: ObservableObject, IslandFeature {
    let id = "pomodoro"
    let title = "Помодоро"
    let icon = "timer"
    let contentHeight: CGFloat = 250

    static let studyTarget: TimeInterval = 50 * 60
    static let shortRest: TimeInterval = 10 * 60
    static let longRest: TimeInterval = 30 * 60
    static let roundsPerCycle = 4

    enum Phase: String, Codable { case idle, study, rest }

    struct Session: Codable {
        var phase: Phase = .idle
        var phaseStart = Date()
        /// Сколько учёб завершено в текущем цикле (0...4).
        var completed = 0
        /// До какого момента текущая учёба уже записана в `days`.
        var lastFlush = Date()
    }

    private struct Store: Codable {
        /// "yyyy-MM-dd" → секунды учёбы
        var days: [String: TimeInterval]
        var session: Session
    }

    @Published private(set) var days: [String: TimeInterval] = [:]
    @Published private(set) var session = Session()

    private var alarm: Timer?
    private var flushTimer: Timer?
    /// false, если файл не прочитался, — тогда не пишем поверх него.
    private var canSave = true

    private static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BigIsland/pomodoro.json")

    var restTarget: TimeInterval {
        session.completed >= Self.roundsPerCycle ? Self.longRest : Self.shortRest
    }

    var target: TimeInterval? {
        switch session.phase {
        case .idle: nil
        case .study: Self.studyTarget
        case .rest: restTarget
        }
    }

    // MARK: - IslandFeature

    func start() {
        load()
        // Приложение было выключено дольше пары минут — этот промежуток учёбой не считаем.
        if session.phase == .study, Date().timeIntervalSince(session.lastFlush) > 120 {
            session.lastFlush = Date()
        }
        phaseChanged()
    }

    func stop() { flush() }

    func makeView() -> AnyView { AnyView(PomodoroView(feature: self)) }

    // MARK: - Действия

    func startStudy() {
        if session.completed >= Self.roundsPerCycle { session.completed = 0 }
        let now = Date()
        session.phase = .study
        session.phaseStart = now
        session.lastFlush = now
        phaseChanged()
    }

    func finishStudy() {
        flush()
        session.completed += 1
        session.phase = .rest
        session.phaseStart = Date()
        phaseChanged()
    }

    /// Сброс цикла. Уже набранное время учёбы сохраняется.
    func reset() {
        flush()
        session = Session()
        phaseChanged()
    }

    /// Учёба за день, включая ещё не записанный хвост текущей сессии.
    func studied(on key: String, now: Date = Date()) -> TimeInterval {
        let saved = days[key] ?? 0
        guard session.phase == .study else { return saved }
        let live = Self.split(from: session.lastFlush, to: now, calendar: .current)
        return saved + live.filter { $0.key == key }.reduce(0) { $0 + $1.seconds }
    }

    // MARK: - Внутреннее

    private func phaseChanged() {
        alarm?.invalidate()
        alarm = nil
        flushTimer?.invalidate()
        flushTimer = nil

        if let target {
            let fire = session.phaseStart.addingTimeInterval(target)
            if fire > Date() {
                let sound = session.phase == .study ? "Glass" : "Hero"
                let timer = Timer(fire: fire, interval: 0, repeats: false) { _ in
                    NSSound(named: sound)?.play()
                }
                RunLoop.main.add(timer, forMode: .common)
                alarm = timer
            }
        }
        if session.phase == .study {
            // Раз в минуту пишем учёбу на диск: при сбое теряется не больше минуты.
            flushTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.flush() }
            }
        }
        save()
    }

    private func flush() {
        guard session.phase == .study else { return }
        let now = Date()
        for part in Self.split(from: session.lastFlush, to: now, calendar: .current) {
            days[part.key, default: 0] += part.seconds
        }
        session.lastFlush = now
        save()
    }

    /// Режет интервал по полуночам: учёба 23:30–00:30 даст по 30 минут двум дням.
    nonisolated static func split(from: Date, to: Date, calendar: Calendar) -> [(key: String, seconds: TimeInterval)] {
        var result: [(key: String, seconds: TimeInterval)] = []
        var start = from
        while start < to {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
            let end = min(to, nextDay)
            result.append((dayKey(start, calendar: calendar), end.timeIntervalSince(start)))
            start = end
        }
        return result
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        do {
            let store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: Self.fileURL))
            days = store.days
            session = store.session
        } catch {
            // Никогда не затираем историю: откладываем копию и больше не пишем в файл до перезапуска.
            canSave = false
            let backup = Self.fileURL.deletingPathExtension()
                .appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: Self.fileURL, to: backup)
            NSLog("BigIsland: не прочитал \(Self.fileURL.path): \(error). Копия: \(backup.path)")
        }
    }

    private func save() {
        guard canSave else { return }
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Store(days: days, session: session))
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("BigIsland: не сохранил помодоро: \(error)")
        }
    }
}

func selfTest() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Almaty")!
    let start = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 23, minute: 30))!
    let end = cal.date(from: DateComponents(year: 2026, month: 9, day: 17, hour: 0, minute: 45))!
    let parts = PomodoroFeature.split(from: start, to: end, calendar: cal)
    precondition(parts.map(\.key) == ["2026-09-16", "2026-09-17"], "\(parts)")
    precondition(parts.map(\.seconds) == [30 * 60, 45 * 60], "\(parts)")
    precondition(PomodoroFeature.split(from: end, to: end, calendar: cal).isEmpty)
    print("selftest ok")
}
