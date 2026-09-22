import AppKit
import IOKit.ps
import SwiftUI

/// Аналог Amphetamine: Mac не засыпает, даже с закрытой крышкой (можно убрать в сумку).
/// Работает через `pmset -a disablesleep 1` — это root. Первое включение спрашивает пароль и заодно
/// ставит правило `/etc/sudoers.d/bigisland` только на эти две команды pmset, дальше — без пароля (`sudo -n`).
@MainActor
final class AwakeFeature: ObservableObject, IslandFeature {
    let id = "awake"
    let title = "Не спать"
    let icon = "cup.and.saucer"

    /// На батарее ниже этого — выключаемся сами, чтобы Mac в сумке успел уснуть, а не умер.
    nonisolated static let minBattery = 10
    nonisolated static let sudoers = "/etc/sudoers.d/bigisland"

    @Published private(set) var isOn = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private var batteryTimer: Timer?

    func start() {
        isOn = Self.sleepDisabled()
        if isOn { watchBattery() }
    }

    /// Выход из приложения не должен оставить Mac вечно бодрствующим.
    func stop() {
        guard isOn else { return }
        _ = Self.pmset(false, allowPrompt: false)
    }

    func makeView() -> AnyView { AnyView(AwakeView(feature: self)) }

    func toggle() {
        let on = !isOn
        if on, let level = Self.batteryLevel(), level < Self.minBattery {
            error = "Батарея \(level)% — подключи зарядку"
            return
        }
        busy = true
        error = nil
        // Окно пароля блокирует поток — не на главном.
        Task.detached {
            let failure = Self.pmset(on, allowPrompt: true)
            let actual = Self.sleepDisabled()
            await MainActor.run { self.apply(actual, failure: failure) }
        }
    }

    private func apply(_ on: Bool, failure: String?) {
        busy = false
        isOn = on
        error = failure
        if on { watchBattery() } else { batteryTimer?.invalidate(); batteryTimer = nil }
    }

    private func watchBattery() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let level = Self.batteryLevel(), level < Self.minBattery else { return }
                _ = Self.pmset(false, allowPrompt: false)
                self.apply(Self.sleepDisabled(), failure: "Выключено: батарея \(level)%")
            }
        }
    }

    // MARK: - Система

    /// nil — получилось, иначе текст ошибки.
    nonisolated static func pmset(_ on: Bool, allowPrompt: Bool) -> String? {
        let value = on ? "1" : "0"
        if run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value]).status == 0 { return nil }
        guard allowPrompt else { return "Нет прав на pmset" }

        // ponytail: имя пользователя без пробелов (иначе правило sudoers надо экранировать).
        let rule = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bigisland.sudoers").path
        do { try rule.write(toFile: tmp, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        let shell = "/usr/sbin/visudo -cf '\(tmp)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp)' \(sudoers)"
            + " && /usr/bin/pmset -a disablesleep \(value)"
        let script = "do shell script \"\(shell)\" with administrator privileges"
        let result = run("/usr/bin/osascript", ["-e", script])
        try? FileManager.default.removeItem(atPath: tmp)
        if result.status == 0 { return nil }
        return result.output.contains("-128") ? "Отменено" : result.output
    }

    /// Правда из системы, а не наш флаг: переживает перезапуск и падение приложения.
    nonisolated static func sleepDisabled() -> Bool {
        run("/usr/bin/pmset", ["-g"]).output.split(separator: "\n").contains {
            $0.contains("SleepDisabled") && $0.hasSuffix("1")
        }
    }

    /// Процент батареи, если питаемся от неё; nil — от сети или батареи нет.
    nonisolated static func batteryLevel() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let level = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            return level
        }
        return nil
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

// MARK: - UI

struct AwakeView: View {
    @ObservedObject var feature: AwakeFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.isOn ? "Mac не уснёт" : "Обычный сон")
                .font(.system(size: 14, weight: .semibold)).tracking(-0.224)
                .foregroundStyle(feature.isOn ? Theme.accent : Theme.muted)
            Text("Даже с закрытой крышкой — можно убрать в сумку. Экран гаснет, всё остальное работает. "
                 + "На батарее ниже \(AwakeFeature.minBattery)% выключится само.")
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundStyle(Theme.muted)
            if let error = feature.error {
                Text(error)
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            PillButton(title: feature.isOn ? "Выключить" : "Не спать", icon: feature.isOn ? "moon.fill" : "cup.and.saucer.fill",
                       primary: !feature.isOn, action: feature.toggle)
                .disabled(feature.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
