import AVFoundation
import NaturalLanguage
import Security
import SwiftUI

/// Озвучка текста: вставил текст, и он зазвучал. Grok TTS через OpenRouter.
/// Текст режется на фрагменты по предложениям: первый короткий, чтобы звук начался быстрее,
/// следующие качаются заранее, но не больше чем на 2 фрагмента вперёд (не тратим деньги, если остановишь).
@MainActor
final class SpeechFeature: NSObject, ObservableObject, IslandFeature, AVAudioPlayerDelegate {
    let id = "speech"
    let title = "Озвучка"
    let icon = "waveform"
    let contentHeight: CGFloat = 170

    nonisolated static let model = "x-ai/grok-voice-tts-1.0"
    nonisolated static let voice = "eve"

    @Published var text = ""
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false
    @Published private(set) var isLoading = false
    @Published private(set) var current = 0
    @Published private(set) var chunkCount = 0
    @Published private(set) var error: String?

    private var chunks: [String] = []
    private var audio: [Int: Data] = [:]
    private var nextFetch = 0
    private var fetching: Task<Void, Never>?
    private var player: AVAudioPlayer?

    func start() {}
    func stop() { reset() }
    func makeView() -> AnyView { AnyView(SpeechView(feature: self)) }

    // MARK: - Управление

    func speak() {
        reset()
        chunks = Self.chunks(of: text)
        guard !chunks.isEmpty else { return }
        chunkCount = chunks.count
        isActive = true
        isLoading = true
        error = nil
        fetchMore()
    }

    func togglePause() {
        guard isActive else { speak(); return }
        isPaused.toggle()
        if isPaused { player?.pause() } else if let player { player.play() } else { playCurrent() }
    }

    func reset() {
        fetching?.cancel()
        fetching = nil
        player?.stop()
        player = nil
        chunks = []
        audio = [:]
        nextFetch = 0
        current = 0
        chunkCount = 0
        isActive = false
        isPaused = false
        isLoading = false
    }

    // MARK: - Загрузка и воспроизведение

    private func fetchMore() {
        guard fetching == nil, nextFetch < chunks.count, nextFetch <= current + 2 else { return }
        let index = nextFetch, chunk = chunks[index]
        nextFetch += 1
        fetching = Task {
            do {
                let data = try await Self.synthesize(chunk)
                guard !Task.isCancelled else { return }
                fetching = nil
                audio[index] = data
                if player == nil, !isPaused, index == current { playCurrent() }
                fetchMore()
            } catch {
                guard !Task.isCancelled else { return }
                reset()
                self.error = error.localizedDescription
            }
        }
    }

    private func playCurrent() {
        guard let data = audio.removeValue(forKey: current) else { isLoading = true; return } // ещё качается
        do {
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.play()
            self.player = player
            isLoading = false
            fetchMore()
        } catch {
            reset()
            self.error = "Не удалось проиграть звук"
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated {
            guard finished === player else { return }
            player = nil
            current += 1
            if current < chunks.count { playCurrent() } else { reset() }
        }
    }

    // MARK: - Сеть и ключ

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    nonisolated static func synthesize(_ text: String) async throws -> Data {
        guard let key = apiKey() else {
            throw Failure(errorDescription: "Нет ключа OpenRouter. В терминале: security add-generic-password -s BigIsland -a openrouter -w")
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "voice": voice, "input": text, "response_format": "mp3",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw Failure(errorDescription: message ?? "Ошибка сервера")
        }
        return data
    }

    /// Ключ из связки ключей; переменная окружения — для запуска из терминала.
    /// Читается не на главном потоке: при первом доступе macOS может спросить разрешение.
    nonisolated static func apiKey() -> String? {
        if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] { return key }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "BigIsland",
            kSecAttrAccount: "openrouter",
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Нарезка

    /// Фрагменты по границам предложений: первый до `first` символов, остальные до `rest`.
    // ponytail: предложение длиннее `rest` режется по символам, возможно посреди слова.
    nonisolated static func chunks(of text: String, first: Int = 200, rest: Int = 1500) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = [], buffer = ""
        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            buffer = ""
        }
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            var sentence = text[range]
            while sentence.count > rest {
                flush()
                buffer = String(sentence.prefix(rest))
                flush()
                sentence = sentence.dropFirst(rest)
            }
            if buffer.count + sentence.count > (result.isEmpty ? first : rest) { flush() }
            buffer += sentence
            return true
        }
        flush()
        return result
    }
}

// MARK: - UI

struct SpeechView: View {
    @ObservedObject var feature: SpeechFeature

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            TextEditor(text: $feature.text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Theme.tile, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if feature.text.isEmpty {
                        Label("Вставь текст, и он зазвучит", systemImage: "waveform")
                            .font(.system(size: 14)).tracking(-0.224)
                            .foregroundStyle(Theme.muted)
                            .padding(.leading, 13).padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: feature.text) { old, new in
                    // Вставка (⌘V) добавляет сразу много символов, набор — по одному.
                    if new.utf16.count - old.utf16.count > 1 { feature.speak() }
                }

            Rectangle().fill(Theme.hairline).frame(width: 1)

            VStack(alignment: .leading, spacing: 8) {
                Text(status)
                    .font(.system(size: 12, weight: .semibold)).tracking(-0.12)
                    .foregroundStyle(feature.isActive && !feature.isPaused ? Theme.accent : Theme.muted)

                if feature.isActive {
                    ProgressView(value: Double(feature.current), total: Double(max(feature.chunkCount, 1)))
                        .tint(Theme.accent)
                        .controlSize(.small)
                }

                if let error = feature.error {
                    Text(error)
                        .font(.system(size: 12)).tracking(-0.12)
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    PillButton(title: playTitle, icon: feature.isActive && !feature.isPaused ? "pause.fill" : "play.fill",
                               primary: true, action: feature.togglePause)
                    if feature.isActive {
                        Button(action: feature.reset) {
                            Image(systemName: "stop.fill").font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(PressStyle())
                        .help("Остановить")
                    }
                }
            }
            .frame(width: 200, alignment: .leading)
        }
    }

    private var status: String {
        guard feature.isActive else { return "Озвучка" }
        let progress = "\(feature.current + 1)/\(feature.chunkCount)"
        if feature.isPaused { return "Пауза · \(progress)" }
        return feature.isLoading ? "Загрузка · \(progress)" : "Звучит · \(progress)"
    }

    private var playTitle: String {
        guard feature.isActive else { return "Озвучить" }
        return feature.isPaused ? "Дальше" : "Пауза"
    }
}
