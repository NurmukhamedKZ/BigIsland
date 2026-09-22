import AppKit
import CoreAudio
import SwiftUI

/// Микшер: все приложения, которые сейчас играют звук, и у каждого своя громкость и mute.
/// Core Audio process taps (macOS 14.4+): пока громкость приложения не 100% или оно выключено, его звук
/// перехватывается (`mutedWhenTapped` — оригинал глохнет) и заново играется в текущий выход с нашим усилением.
/// На 100% без mute тапа нет вообще — ноль накладных расходов. Нужно разрешение «Запись системного звука».
@MainActor
final class MixerFeature: ObservableObject, IslandFeature {
    let id = "mixer"
    let title = "Звук"
    let icon = "speaker.wave.2"

    struct App: Identifiable {
        let id: String
        let name: String
        let icon: NSImage
        let processes: [AudioObjectID]
        let playing: Bool
    }

    struct Setting: Equatable {
        var volume: Float = 1
        var muted = false
        var gain: Float { muted ? 0 : volume }
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var settings: [String: Setting] = [:]
    @Published private(set) var error: String?
    private var taps: [String: AppTap] = [:]
    private var timer: Timer?
    private var owners: [pid_t: Owner] = [:]
    typealias Owner = (id: String, name: String, icon: NSImage)

    func start() {
        // Событийно: появился/исчез аудиопроцесс или сменился выход (наушники) — пересобираем.
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    func stop() {
        taps.values.forEach { $0.close() }
        taps = [:]
    }

    func makeView() -> AnyView { AnyView(MixerView(feature: self)) }

    /// «Играет ли сейчас» у процесса событий не шлёт удобно — опрашиваем, но только пока вкладка на экране.
    func setVisible(_ visible: Bool) {
        timer?.invalidate()
        timer = nil
        guard visible else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func setVolume(_ volume: Float, for id: String) {
        var setting = settings[id] ?? Setting()
        setting.volume = volume
        update(setting, for: id)
    }

    func toggleMute(_ id: String) {
        var setting = settings[id] ?? Setting()
        setting.muted.toggle()
        update(setting, for: id)
    }

    private func update(_ setting: Setting, for id: String) {
        settings[id] = setting == Setting() ? nil : setting
        if let tap = taps[id] {
            tap.gain.value = setting.gain
        }
        syncTaps()
    }

    // MARK: - Процессы

    func refresh() {
        var groups: [String: (name: String, icon: NSImage, processes: [AudioObjectID], playing: Bool)] = [:]
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for object in Self.processObjects() {
            guard let pid: pid_t = Self.property(object, kAudioProcessPropertyPID), pid != ownPID else { continue }
            let playing = (Self.property(object, kAudioProcessPropertyIsRunningOutput) as UInt32?) ?? 0 != 0
            // Демоны без приложения (Siri, системные звуки) не показываем.
            guard let owner = owners[pid] ?? Self.owner(of: pid, bundleID: Self.bundleID(object)) else { continue }
            owners[pid] = owner
            var group = groups[owner.id] ?? (owner.name, owner.icon, [], false)
            group.processes.append(object)
            group.playing = group.playing || playing
            groups[owner.id] = group
        }
        let list = groups
            .filter { $0.value.playing || settings[$0.key] != nil }
            .map { App(id: $0.key, name: $0.value.name, icon: $0.value.icon, processes: $0.value.processes, playing: $0.value.playing) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list.map(\.id) != apps.map(\.id) || list.map(\.playing) != apps.map(\.playing) || list.map(\.processes) != apps.map(\.processes) {
            apps = list
        }
        syncTaps()
    }

    /// Тап есть ровно у приложений с настройкой; пересоздаём, если сменились его процессы или выход.
    private func syncTaps() {
        let output = Self.defaultOutputUID()
        for (id, tap) in taps where settings[id] == nil || tap.outputUID != output
            || Set(tap.processes) != Set(apps.first { $0.id == id }?.processes ?? tap.processes) {
            tap.close()
            taps[id] = nil
        }
        guard let output else { return }
        for app in apps where taps[app.id] == nil {
            guard let setting = settings[app.id] else { continue }
            do {
                taps[app.id] = try AppTap(processes: app.processes, outputUID: output, gain: setting.gain)
                error = nil
            } catch {
                self.error = "\(app.name): \(error.localizedDescription)"
            }
        }
    }

    /// Звук браузера играет helper/XPC-процесс (Chrome Helper, WebKit.GPU) — приписываем его приложению-владельцу.
    private static func owner(of pid: pid_t, bundleID: String?) -> Owner? {
        guard let app = NSRunningApplication(processIdentifier: responsiblePID(pid)) ?? NSRunningApplication(processIdentifier: pid)
                ?? bundleID.flatMap(runningApp(prefixOf:)),
              app.activationPolicy != .prohibited, let id = app.bundleIdentifier else { return nil }
        return (id, app.localizedName ?? id, app.icon ?? NSImage())
    }

    /// com.google.Chrome.helper → запущенный com.google.Chrome.
    private static func runningApp(prefixOf bundleID: String) -> NSRunningApplication? {
        var parts = bundleID.split(separator: ".")
        while parts.count > 1 {
            parts.removeLast()
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: parts.joined(separator: ".")).first {
                return app
            }
        }
        return nil
    }

    /// Приватная, но стабильная функция libsystem: для XPC-сервиса возвращает pid приложения, ради которого он запущен.
    private static let responsibilityFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsiblePID(_ pid: pid_t) -> pid_t {
        let owner = responsibilityFn?(pid) ?? pid
        return owner > 0 ? owner : pid
    }

    // MARK: - Core Audio

    nonisolated static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    nonisolated static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.move()
    }

    nonisolated static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        (property(object, selector) as Unmanaged<CFString>?).map { $0.takeRetainedValue() as String }
    }

    nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
    }

    nonisolated static func defaultOutputUID() -> String? {
        guard let device: AudioDeviceID = property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown else { return nil }
        return string(device, kAudioDevicePropertyDeviceUID)
    }
}

/// Усиление читается из аудиопотока без блокировок: гонка на одном Float безвредна.
final class Gain: @unchecked Sendable {
    var value: Float
    init(_ value: Float) { self.value = value }
}

/// Тап процессов приложения + приватное агрегатное устройство «тап → текущий выход» с IOProc, умножающим на gain.
@MainActor
final class AppTap {
    let processes: [AudioObjectID]
    let outputUID: String
    let gain: Gain
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    struct Failure: LocalizedError {
        let step: String
        let status: OSStatus
        var errorDescription: String? { "\(step) (\(status))" }
    }

    init(processes: [AudioObjectID], outputUID: String, gain: Float) throws {
        self.processes = processes
        self.outputUID = outputUID
        self.gain = Gain(gain)

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        try check("тап", AudioHardwareCreateProcessTap(description, &tapID))

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "BigIsland Mixer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        try check("устройство", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID))

        let gainBox = self.gain
        try check("поток", AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) { _, input, _, output, _ in
            Self.render(input, output, gain: gainBox.value)
        })
        try check("старт", AudioDeviceStart(deviceID, procID))
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status != noErr else { return }
        close()
        throw Failure(step: step, status: status)
    }

    func close() {
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    /// Аудиопоток реального времени: без аллокаций и блокировок. Float32 interleaved (формат тапа и HAL).
    /// Тап — последний входной буфер (перед ним могут быть входы самого выхода, например микрофон гарнитуры).
    nonisolated static func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, gain: Float) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let source = inputs.last
        for out in outputs {
            guard let dst = out.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let outChannels = Int(max(out.mNumberChannels, 1))
            let outCount = Int(out.mDataByteSize) / MemoryLayout<Float>.size
            guard let source, let src = source.mData?.assumingMemoryBound(to: Float.self) else {
                dst.update(repeating: 0, count: outCount)
                continue
            }
            let inChannels = Int(max(source.mNumberChannels, 1))
            let frames = min(Int(source.mDataByteSize) / MemoryLayout<Float>.size / inChannels, outCount / outChannels)
            for frame in 0..<frames {
                for channel in 0..<outChannels {
                    dst[frame * outChannels + channel] = src[frame * inChannels + min(channel, inChannels - 1)] * gain
                }
            }
            let rest = frames * outChannels
            if rest < outCount { (dst + rest).update(repeating: 0, count: outCount - rest) }
        }
    }
}

// MARK: - UI

struct MixerView: View {
    @ObservedObject var feature: MixerFeature

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if feature.apps.isEmpty {
                Text("Сейчас ничего не играет")
                    .font(.system(size: 14, weight: .semibold)).tracking(-0.224)
                    .foregroundStyle(Theme.muted)
                Text("Здесь появятся приложения со звуком: браузер, музыка, звонки. У каждого — своя громкость.")
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundStyle(Theme.muted)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(feature.apps) { row($0) }
                    }
                }
            }
            if let error = feature.error {
                Text(error)
                    .font(.system(size: 12)).tracking(-0.12)
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { feature.setVisible(true) }
        .onDisappear { feature.setVisible(false) }
    }

    private func row(_ app: MixerFeature.App) -> some View {
        let setting = feature.settings[app.id] ?? MixerFeature.Setting()
        return HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(app.playing ? 1 : 0.5)
            Text(app.name)
                .font(.system(size: 12)).tracking(-0.12)
                .foregroundStyle(app.playing ? .white : Theme.faint)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Button { feature.toggleMute(app.id) } label: {
                Image(systemName: setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(setting.muted ? Theme.faint : Theme.accent)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(PressStyle())
            Slider(value: Binding(get: { Double(setting.volume) },
                                  set: { feature.setVolume(Float($0), for: app.id) }), in: 0...1)
                .controlSize(.small)
                .tint(Theme.accent)
                .disabled(setting.muted)
            Text("\(Int((setting.volume * 100).rounded()))%")
                .font(.system(size: 12)).tracking(-0.12)
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 26)
    }
}
