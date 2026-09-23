import AppKit
import Carbon
import SwiftUI

/// Автопереключение раскладки RU ⇄ EN, как Punto Switcher. Слушаем нажатия (`CGEventTap`, нужен «Универсальный доступ»),
/// на пробеле решаем по `LayoutRules`: стираем слово (и короткие слова перед ним, если они тоже были не в той раскладке),
/// печатаем в нужной раскладке и переключаем раскладку.
/// В редакторах кода и терминалах — строгий режим, а Return/Tab там не заканчивают слово (это автодополнение).
/// Двойное нажатие ⌥ — перевести последнее слово вручную; отмена автозамены запоминает слово в исключения.
@MainActor
final class LayoutFeature: ObservableObject, IslandFeature {
    let id = "layout"
    let title = "Раскладка"
    let icon = "globe"

    @Published private(set) var enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
    @Published private(set) var hasAccess = AXIsProcessTrusted()
    @Published private(set) var frontApp = ""
    @Published private(set) var codeMode = false
    @Published private(set) var lastFix: String?
    @Published private(set) var exceptions = Set(UserDefaults.standard.stringArray(forKey: Keys.exceptions) ?? [])
    /// Ручной выбор режима кода: bundle id → вкл/выкл, перекрывает встроенный список `codeApps`.
    private var codeOverrides = UserDefaults.standard.dictionary(forKey: Keys.codeOverrides) as? [String: Bool] ?? [:]
    private var frontBundle = ""

    private enum Keys {
        static let enabled = "layout.enabled"
        static let exceptions = "layout.exceptions"
        static let codeOverrides = "layout.codeOverrides"
    }

    nonisolated static let marker: Int64 = 0x4249_534C // наши собственные нажатия
    private static let space: UInt16 = 49, backspace: UInt16 = 51
    private static let enders: Set<UInt16> = [space, 36, 48, 76] // пробел, Return, Tab, Enter
    // ponytail: список вручную; добавить приложение — одна строка.
    private static let codeApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf", "dev.zed.Zed",
        "com.apple.dt.Xcode", "com.sublimetext.4", "com.panic.Nova", "com.apple.Terminal", "com.googlecode.iterm2",
        "com.cmuxterm.app", "com.mitchellh.ghostty", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "io.alacritty",
    ]

    private var tap: CFMachPort?
    private var accessTimer: Timer?
    private var typing = Typing()
    private var optionDown = false
    private var lastOptionTap: TimeInterval = 0

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appChanged() }
        }
        appChanged()
        if enabled { startTap(prompt: true) }
    }

    func stop() { stopTap() }
    func makeView() -> AnyView { AnyView(LayoutView(feature: self)) }

    func toggle() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: Keys.enabled)
        if enabled { startTap(prompt: true) } else { stopTap() }
    }

    func openAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func clearExceptions() {
        exceptions = []
        UserDefaults.standard.removeObject(forKey: Keys.exceptions)
    }

    private func appChanged() {
        reset()
        let app = NSWorkspace.shared.frontmostApplication
        frontApp = app?.localizedName ?? ""
        frontBundle = app?.bundleIdentifier ?? ""
        codeMode = Self.isCodeApp(frontBundle, overrides: codeOverrides)
    }

    static func isCodeApp(_ bundle: String, overrides: [String: Bool]) -> Bool {
        overrides[bundle] ?? (codeApps.contains(bundle) || bundle.hasPrefix("com.jetbrains."))
    }

    /// Включить/выключить режим кода для текущего приложения. Совпало со встроенным списком — убираем запись.
    func toggleCodeMode() {
        guard !frontBundle.isEmpty else { return }
        codeOverrides[frontBundle] = !codeMode
        if Self.isCodeApp(frontBundle, overrides: [:]) == !codeMode { codeOverrides[frontBundle] = nil }
        UserDefaults.standard.set(codeOverrides, forKey: Keys.codeOverrides)
        codeMode.toggle()
    }

    // MARK: - Перехват клавиш

    private func startTap(prompt: Bool) {
        guard tap == nil else { return }
        hasAccess = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary)
        guard hasAccess else {
            // Ждём, пока дадут доступ в Настройках. Таймер живёт только до этого момента.
            accessTimer?.invalidate()
            accessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, AXIsProcessTrusted() else { return }
                    self.accessTimer?.invalidate()
                    self.accessTimer = nil
                    if self.enabled { self.startTap(prompt: false) }
                }
            }
            return
        }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
        let callback: CGEventTapCallBack = { _, type, event, info in
            let feature = Unmanaged<LayoutFeature>.fromOpaque(info!).takeUnretainedValue()
            let pass = MainActor.assumeIsolated { feature.handle(type, event) }
            return pass ? Unmanaged.passUnretained(event) : nil
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        self.tap = tap
    }

    private func stopTap() {
        accessTimer?.invalidate()
        accessTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        reset()
    }

    private func reset() { typing.reset() }

    /// false — событие проглатываем (заменили его своими).
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return true }
        // Поля паролей: система включает защищённый ввод, туда не смотрим.
        guard !IsSecureEventInputEnabled() else { reset(); return true }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let shortcut: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]
        switch type {
        case .flagsChanged:
            // ⌥ нажали и отпустили без других клавиш, дважды подряд — ручной перевод.
            if [58, 61].contains(code), flags.intersection(shortcut.union(.maskShift)) == .maskAlternate {
                optionDown = true
            } else if optionDown, flags.intersection(shortcut).isEmpty {
                optionDown = false
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastOptionTap < NSEvent.doubleClickInterval {
                    lastOptionTap = 0
                    convertManually()
                } else {
                    lastOptionTap = now
                }
            } else {
                optionDown = false
            }
        case .keyDown:
            optionDown = false
            lastOptionTap = 0
            if !flags.intersection(shortcut).isEmpty {
                reset()
            } else if code == Self.backspace {
                typing.backspace()
            } else if Self.enders.contains(code) {
                return endWord(code: code, flags: flags)
            } else if let char = KeyLayout.current?.translate([Key(code: code)]).unicodeScalars.first,
                      char.value > 0x20, char.value != 0x7F, !(0xF700...0xF8FF).contains(char.value) {
                typing.letter(Key(code: code, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
            } else {
                reset() // стрелки, Esc, F-клавиши: каретка ушла
            }
        default:
            optionDown = false
            reset() // клик мышью
        }
        return true
    }

    private func endWord(code: UInt16, flags: CGEventFlags) -> Bool {
        // Return/Tab в редакторе — это автодополнение и перенос строки, слово не трогаем.
        guard !(codeMode && code != Self.space), let (from, to) = pair() else { reset(); return true }
        guard let fix = typing.end(space: code == Self.space, from: from, to: to, code: codeMode,
                                   exceptions: exceptions) else { return true }
        apply(fix)
        post(code, flags: flags.intersection(.maskShift))
        return false
    }

    /// Двойной ⌥. Отмена нашей замены запоминает слово в исключения.
    private func convertManually() {
        guard let (fix, exception) = typing.manual(pair: pair()) else { return }
        apply(fix)
        if let exception {
            exceptions.insert(exception)
            UserDefaults.standard.set(Array(exceptions), forKey: Keys.exceptions)
        }
    }

    private func apply(_ fix: Typing.Fix) {
        replace(fix.erase, with: fix.text)
        fix.target.select()
        lastFix = fix.text
    }

    /// Текущая раскладка и её пара. Работаем только между русской и английской (казахская и прочие — мимо).
    private func pair() -> (KeyLayout, KeyLayout)? {
        guard let current = KeyLayout.current, ["en", "ru"].contains(current.lang) else { return nil }
        let wanted = current.lang == "en" ? "ru" : "en"
        guard let other = KeyLayout.list().first(where: { $0.lang == wanted }) else { return nil }
        return (current, other)
    }

    // MARK: - Печать

    private let source = CGEventSource(stateID: .hidSystemState)

    private func replace(_ count: Int, with text: String) {
        for _ in 0..<count { post(Self.backspace) }
        // Символы, а не коды клавиш: не зависим от того, когда приложение заметит смену раскладки.
        for char in text { post(0, unicode: Array(String(char).utf16)) }
    }

    private func post(_ code: UInt16, flags: CGEventFlags = [], unicode: [UniChar]? = nil) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            event.flags = flags
            if let unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

// MARK: - UI

struct LayoutView: View {
    @ObservedObject var feature: LayoutFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(status)
                    .font(.system(size: 14, weight: .semibold)).tracking(-0.224)
                    .foregroundStyle(feature.enabled && feature.hasAccess ? Theme.accent : Theme.muted)
                if !feature.frontApp.isEmpty {
                    // Клик — включить/выключить режим кода для этого приложения.
                    Button(action: feature.toggleCodeMode) {
                        Label("\(feature.frontApp) · режим кода",
                              systemImage: feature.codeMode ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12)).tracking(-0.12)
                            .foregroundStyle(feature.codeMode ? Theme.accent : Theme.faint)
                    }
                    .buttonStyle(PressStyle())
                }
                Spacer(minLength: 0)
                if let fix = feature.lastFix {
                    Text(fix)
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Text("Набрал «ghbdtn» — станет «привет». В редакторах и терминалах английский код не трогаю, Return и Tab не переводят. Двойной ⌥ — перевести последнее слово; если это моя ошибка, запомню слово.")
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                if feature.enabled && !feature.hasAccess {
                    PillButton(title: "Дать доступ", icon: "lock.open", primary: true, action: feature.openAccessSettings)
                }
                PillButton(title: feature.enabled ? "Выключить" : "Включить", icon: "power",
                           primary: !feature.enabled, action: feature.toggle)
                if !feature.exceptions.isEmpty {
                    Button("Сбросить исключения (\(feature.exceptions.count))", action: feature.clearExceptions)
                        .buttonStyle(.plain)
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        if !feature.enabled { return "Выключено" }
        return feature.hasAccess ? "Работает" : "Нужен «Универсальный доступ»"
    }
}
