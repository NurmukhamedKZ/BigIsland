import SwiftUI

/// Токены дизайна (по design.md, тёмная сторона: остров всегда чёрный).
enum Theme {
    /// Единственный акцент: текст, ссылки, иконки, прогресс на тёмном.
    static let accent = Color(hex: 0x2997FF)
    /// Заливка основной кнопки-капсулы (белый текст).
    static let action = Color(hex: 0x0066CC)
    static let tile = Color(hex: 0x272729)
    static let muted = Color(hex: 0xCCCCCC)
    static let faint = Color(hex: 0x7A7A7A)
    static let hairline = Color.white.opacity(0.1)

    /// Скругление ячеек и превью; у кнопок — капсула.
    static let radius: CGFloat = 8
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Наведение — светлая подложка, нажатие — сжатие до 0.95.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }
}

private struct PressBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            // Подложка шире кнопки, но на раскладку не влияет.
            .background(Capsule().fill(.white.opacity(hovered ? 0.1 : 0)).padding(.horizontal, -1.5).padding(.vertical, -1))
            .brightness(hovered ? 0.12 : 0)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}
