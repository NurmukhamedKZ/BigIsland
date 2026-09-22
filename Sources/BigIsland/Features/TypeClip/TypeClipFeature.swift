import SwiftUI

/// Запуск `~/.local/bin/typeclip 5`: через 5 с печатает буфер обмена как нажатия клавиш.
/// За эти 5 с успеваешь поставить курсор в нужное поле другого приложения.
@MainActor
final class TypeClipFeature: ObservableObject, IslandFeature {
    let id = "typeclip"
    let title = "Набор"
    let icon = "keyboard"

    nonisolated static let delay = 5
    nonisolated static let script = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/typeclip")

    /// Время запуска; nil — скрипт не работает.
    @Published private(set) var startedAt: Date?
    @Published private(set) var error: String?
    private var process: Process?

    func start() {}
    func stop() { cancel() }
    func makeView() -> AnyView { AnyView(TypeClipView(feature: self)) }

    func run() {
        guard process == nil else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script.path, String(Self.delay)]
        let stderr = Pipe()
        process.standardError = stderr
        process.terminationHandler = { [weak self] finished in
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failed = finished.terminationReason == .exit && finished.terminationStatus != 0
            Task { @MainActor in
                guard let self, self.process === finished else { return }
                self.process = nil
                self.startedAt = nil
                if failed { self.error = message.isEmpty ? "typeclip завершился с ошибкой" : message }
            }
        }
        do {
            try process.run()
            self.process = process
            startedAt = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        startedAt = nil
    }
}

// MARK: - UI

struct TypeClipView: View {
    @ObservedObject var feature: TypeClipFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(status(at: context.date))
                    .font(.system(size: 14, weight: .semibold)).tracking(-0.224)
                    .foregroundStyle(feature.startedAt == nil ? Theme.muted : Theme.accent)
            }
            Text("Печатает буфер обмена как нажатия клавиш. Поставь курсор в нужное поле, пока идёт отсчёт.")
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundStyle(Theme.muted)
            if let error = feature.error {
                Text(error)
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            if feature.startedAt == nil {
                PillButton(title: "Печатать через \(TypeClipFeature.delay) с", icon: "keyboard",
                           primary: true, action: feature.run)
            } else {
                PillButton(title: "Отмена", icon: "stop.fill", primary: false, action: feature.cancel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func status(at date: Date) -> String {
        guard let startedAt = feature.startedAt else { return "typeclip" }
        let left = TypeClipFeature.delay - Int(date.timeIntervalSince(startedAt))
        return left > 0 ? "Старт через \(left) с" : "Печатаю…"
    }
}
