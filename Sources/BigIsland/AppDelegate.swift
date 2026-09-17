import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Реестр фич. Добавить фичу — одна строка, убрать — удалить строку.
    let features: [any IslandFeature] = [
        ScreenshotsFeature(),
        PomodoroFeature(),
    ]

    private var islands: [IslandController] = []
    private var mouseMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        features.forEach { $0.start() }

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

    /// По острову на каждый экран (с вырезом и без).
    private func buildIslands() {
        islands.forEach { $0.close() }
        islands = NSScreen.screens.map { IslandController(screen: $0, features: features) }
    }
}
