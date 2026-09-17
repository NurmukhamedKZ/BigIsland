import AppKit
import SwiftUI

/// Фича острова = одна вкладка.
@MainActor
protocol IslandFeature: AnyObject {
    var id: String { get }
    var title: String { get }
    /// SF Symbol
    var icon: String { get }
    /// Высота содержимого вкладки (без строки вкладок).
    var contentHeight: CGFloat { get }

    func start()
    func stop()
    func makeView() -> AnyView
}

extension IslandFeature {
    var contentHeight: CGFloat { 150 }
}
