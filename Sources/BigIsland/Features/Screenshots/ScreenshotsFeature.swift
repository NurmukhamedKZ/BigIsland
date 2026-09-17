import AppKit
import ImageIO
import SwiftUI

struct Shot: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage
}

/// Скриншоты из папки (⇧⌘3/4/5) и любые картинки из буфера обмена (⌃⇧⌘4, копирование).
/// Живут только до выхода из приложения.
@MainActor
final class ScreenshotsFeature: ObservableObject, IslandFeature {
    let id = "screenshots"
    let title = "Скриншоты"
    let icon = "camera.viewfinder"

    @Published private(set) var shots: [Shot] = []

    private var folderSource: DispatchSourceFileSystemObject?
    private var knownFiles: Set<String> = []
    private var pasteboardTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private let maxShots = 40
    nonisolated private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff"]
    private let clipboardDir = FileManager.default.temporaryDirectory.appendingPathComponent("BigIsland", isDirectory: true)

    func start() {
        try? FileManager.default.removeItem(at: clipboardDir)
        try? FileManager.default.createDirectory(at: clipboardDir, withIntermediateDirectories: true)
        watchScreenshotFolder()
        // У NSPasteboard нет уведомлений — все менеджеры буфера опрашивают changeCount.
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
    }

    func stop() {
        folderSource?.cancel()
        pasteboardTimer?.invalidate()
    }

    func makeView() -> AnyView { AnyView(ScreenshotsView(feature: self)) }

    func remove(_ shot: Shot) {
        shots.removeAll { $0.id == shot.id }
    }

    // MARK: - Папка скриншотов

    // ponytail: папка читается при запуске; сменил её в ⇧⌘5 — перезапусти приложение.
    private static var screenshotFolder: URL {
        let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") ?? "~/Desktop"
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func watchScreenshotFolder() {
        let folder = Self.screenshotFolder
        // Первый доступ к «Документам» блокируется системным запросом разрешения — не на главном потоке.
        DispatchQueue.global(qos: .utility).async {
            let fd = open(folder.path, O_EVTONLY)
            let known = Self.imageFiles(in: folder)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.attachWatcher(folder: folder, fd: fd, known: known) }
            }
        }
    }

    private func attachWatcher(folder: URL, fd: Int32, known: Set<String>) {
        guard fd >= 0 else { NSLog("BigIsland: не могу открыть \(folder.path)"); return }

        knownFiles = known
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged(folder) }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderSource = source
    }

    private func folderChanged(_ folder: URL) {
        let current = Self.imageFiles(in: folder)
        let added = current.subtracting(knownFiles)
        knownFiles = current
        for name in added.sorted() {
            add(folder.appendingPathComponent(name))
        }
    }

    /// Скрытые файлы пропускаем: macOS сначала пишет «.Screenshot…», потом переименовывает.
    nonisolated static func imageFiles(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names.filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) })
    }

    // MARK: - Буфер обмена

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // Скопированный в Finder файл тоже несёт картинку (иконку) — пропускаем.
        guard pb.types?.contains(.fileURL) != true else { return }
        let png = pb.data(forType: .png)
        let tiff = png == nil ? pb.data(forType: .tiff) : nil
        guard png != nil || tiff != nil else { return }

        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
            .replacingOccurrences(of: ":", with: ".").replacingOccurrences(of: "/", with: "-")
        let url = clipboardDir.appendingPathComponent("Clipboard \(stamp) \(UUID().uuidString.prefix(4)).png")

        // Конвертация и запись — не на главном потоке.
        Task.detached(priority: .userInitiated) {
            guard let data = png ?? tiff.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
                  (try? data.write(to: url)) != nil,
                  let thumb = Self.thumbnail(of: url) else { return }
            await self.insert(url: url, thumbnail: thumb)
        }
    }

    // MARK: - Общее

    private func add(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            guard let thumb = Self.thumbnail(of: url) else { return }
            await self.insert(url: url, thumbnail: thumb)
        }
    }

    private func insert(url: URL, thumbnail: CGImage) {
        shots.insert(Shot(url: url, thumbnail: NSImage(cgImage: thumbnail, size: .zero)), at: 0)
        if shots.count > maxShots { shots.removeLast(shots.count - maxShots) }
    }

    /// Маленькое превью без загрузки полного изображения в память.
    nonisolated static func thumbnail(of url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - UI

struct ScreenshotsView: View {
    @ObservedObject var feature: ScreenshotsFeature

    var body: some View {
        if feature.shots.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "camera.viewfinder").font(.system(size: 22)).foregroundStyle(Theme.accent)
                Text("Сделай скриншот, и он появится здесь")
                    .font(.system(size: 14)).tracking(-0.224)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(feature.shots) { shot in
                        ShotCell(shot: shot) { feature.remove(shot) }
                    }
                }
                .padding(4) // место под увеличение при наведении
            }
        }
    }
}

private struct ShotCell: View {
    let shot: Shot
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        Image(nsImage: shot.thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 160, height: 110)
            .background(Theme.tile)
            .clipShape(shape)
            .overlay(shape.strokeBorder(hovered ? Theme.accent : Theme.hairline, lineWidth: hovered ? 2 : 1))
            .scaleEffect(hovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hovered)
            .onHover { hovered = $0 }
            .onDrag { NSItemProvider(contentsOf: shot.url) ?? NSItemProvider() }
            .onTapGesture(count: 2) { NSWorkspace.shared.open(shot.url) }
            .contextMenu {
                Button("Открыть") { NSWorkspace.shared.open(shot.url) }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([shot.url]) }
                Divider()
                Button("Убрать с острова", action: remove)
            }
            .help(shot.url.lastPathComponent)
    }
}
