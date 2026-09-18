import AppKit
import SwiftUI

@MainActor
final class IslandModel: ObservableObject {
    @Published var isExpanded = false
    @Published var selectedFeatureID: String?

    let features: [any IslandFeature]
    let notch: CGSize
    let hasNotch: Bool

    static let expandedWidth: CGFloat = 700

    /// Размер открытого острова зависит от выбранной вкладки.
    var expandedSize: CGSize {
        CGSize(width: Self.expandedWidth, height: notch.height + (selectedFeature?.contentHeight ?? 150))
    }

    /// Под самую высокую вкладку — таким создаётся окно.
    var maxExpandedSize: CGSize {
        CGSize(width: Self.expandedWidth, height: notch.height + (features.map(\.contentHeight).max() ?? 150))
    }

    /// В свёрнутом виде чуть меньше выреза, чтобы края не выглядывали.
    var size: CGSize {
        isExpanded ? expandedSize : CGSize(width: notch.width - 8, height: notch.height - 2)
    }

    var selectedFeature: (any IslandFeature)? {
        features.first { $0.id == selectedFeatureID } ?? features.first
    }

    init(features: [any IslandFeature], notch: CGSize, hasNotch: Bool) {
        self.features = features
        self.notch = notch
        self.hasNotch = hasNotch
    }
}

/// Окно острова на одном экране: панель и наведение.
@MainActor
final class IslandController {
    let screen: NSScreen
    private let model: IslandModel
    private let panel: NSPanel
    private var trackTimer: Timer?

    private static let shadowPadding: CGFloat = 30

    init(screen: NSScreen, features: [any IslandFeature]) {
        self.screen = screen
        let notch = Self.notchSize(of: screen)
        model = IslandModel(features: features, notch: notch ?? Self.fakeNotch(of: screen), hasNotch: notch != nil)

        // Окно сразу максимального размера: анимируется только форма внутри, не окно.
        let size = model.maxExpandedSize
        let frame = screen.frame
        let rect = NSRect(
            x: frame.midX - size.width / 2 - Self.shadowPadding,
            y: frame.maxY - size.height - Self.shadowPadding,
            width: size.width + Self.shadowPadding * 2,
            height: size.height + Self.shadowPadding
        )

        panel = KeyPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.contentView = FirstMouseHostingView(rootView: IslandView(model: model))
        panel.setFrame(rect, display: false)
        panel.orderFrontRegardless()
    }

    func close() {
        trackTimer?.invalidate()
        panel.close()
    }

    // MARK: - Наведение

    /// Зона, наведение на которую открывает остров (вырез + пара пикселей сверху).
    private var hotRect: NSRect {
        let f = screen.frame
        return NSRect(x: f.midX - model.notch.width / 2, y: f.maxY - model.notch.height,
                      width: model.notch.width, height: model.notch.height + 2)
    }

    private var expandedRect: NSRect {
        let f = screen.frame, s = model.expandedSize
        return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height + 2)
    }

    func mouseMoved(to point: NSPoint) {
        if !model.isExpanded, hotRect.contains(point) { expand() }
    }

    private func expand() {
        model.isExpanded = true
        panel.ignoresMouseEvents = false
        // Пока остров открыт, курсор над нашим окном — глобальный монитор его не видит, опрашиваем сами.
        trackTimer?.invalidate()
        trackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMouseLeft() }
        }
    }

    private func checkMouseLeft() {
        // Зажатая кнопка = идёт drag скриншота, не закрываем.
        guard NSEvent.pressedMouseButtons == 0, !expandedRect.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }

    private func collapse() {
        trackTimer?.invalidate()
        trackTimer = nil
        panel.ignoresMouseEvents = true
        model.isExpanded = false
        // Клавиатура возвращается приложению, в котором работали до клика по острову.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Геометрия экрана

    private static func notchSize(of screen: NSScreen) -> CGSize? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGSize(width: screen.frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
    }

    /// На экране без выреза — невидимая зона по центру строки меню.
    private static func fakeNotch(of screen: NSScreen) -> CGSize {
        CGSize(width: 200, height: max(screen.frame.maxY - screen.visibleFrame.maxY, 24))
    }
}

/// Без этого borderless-окно не принимает ввод с клавиатуры. Приложение при этом не активируется (nonactivatingPanel).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// У приложения нет меню «Правка», поэтому ⌘V/⌘C/⌘X/⌘A/⌘Z сами не доходят до текстового поля.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Коды клавиш, а не символы: на русской раскладке ⌘V даёт «м».
        let action: Selector? = switch (flags, event.keyCode) {
        case (.command, 9): #selector(NSText.paste(_:))
        case (.command, 8): #selector(NSText.copy(_:))
        case (.command, 7): #selector(NSText.cut(_:))
        case (.command, 0): #selector(NSText.selectAll(_:))
        case (.command, 6): Selector(("undo:"))
        case ([.command, .shift], 6): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Клики срабатывают сразу, даже если приложение неактивно.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
