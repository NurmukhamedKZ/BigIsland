import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Реестр фич. Добавить фичу — одна строка, убрать — удалить строку.
    let features: [any IslandFeature] = [
        ScreenshotsFeature(),
        PomodoroFeature(),
        TypeClipFeature(),
        SpeechFeature(),
        LayoutFeature(),
        AwakeFeature(),
        MixerFeature(),
    ]

    private var islands: [IslandController] = []
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        features.forEach { $0.start() }
        registerLoginItem()

        buildIslands()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildIslands() }
        }

        // Движение мыши над другими приложениями. Разрешений не требует.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated {
                let point = NSEvent.mouseLocation
                self?.islands.forEach { $0.mouseMoved(to: point) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        features.forEach { $0.stop() }
    }

    /// Автозапуск при входе: один раз при первом запуске из /Applications (сборка из build/ не регистрируется).
    /// Выключил в «Объектах входа» — повторно не включаем.
    private func registerLoginItem() {
        let key = "loginItemRegistered"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("BigIsland: автозапуск не включился: \(error)")
        }
    }

    /// По острову на каждый экран (с вырезом и без).
    private func buildIslands() {
        islands.forEach { $0.close() }
        islands = NSScreen.screens.map { IslandController(screen: $0, features: features) }
    }
}
