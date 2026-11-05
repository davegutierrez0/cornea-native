import AppKit
import Combine
import CorneaCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var settings = Settings()
    @Published private(set) var displays: [DisplayInfo] = []
    @Published private(set) var status = "Off · original display colors"
    @Published private(set) var error: String?
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var pausedIndefinitely = false
    @Published private(set) var breakPhase = BreakClock.Phase.stopped
    @Published private(set) var breakRemaining = 0
    @Published private(set) var storageBlocked = false
    var changed: (() -> Void)?
    var showBreak: (() -> Void)?
    var hideBreak: (() -> Void)?
    let displayController = DisplayController()
    private var clock = BreakClock()
    private var timer: Timer?
    private var pendingSave: DispatchWorkItem?
    private var pendingApply: DispatchWorkItem?
    private var sleeping = false
    private var shuttingDown = false
    private let settingsURL: URL

    init(settingsURL: URL? = nil) {
        self.settingsURL = settingsURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cornea Native/settings.json")
        if FileManager.default.fileExists(atPath: self.settingsURL.path) {
            do {
                let loaded = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: self.settingsURL))
                try loaded.validate(); settings = loaded
            } catch {
                self.error = "Settings were not loaded or overwritten: \(error.localizedDescription)"
                storageBlocked = true
            }
        }
    }

    var isPaused: Bool { pausedIndefinitely || pausedUntil != nil }
    var effective: ScheduleResult { ScheduleEngine.evaluate(settings, at: Date()) }

    func start() {
        refreshDisplays()
        if settings.breaksEnabled { clock.start(now: ProcessInfo.processInfo.systemUptime, workSeconds: settings.workMinutes * 60) }
        applyNow(); syncBreak(); configureTimer()
    }

    func update(_ edit: (inout Settings) -> Void) {
        guard !storageBlocked else { return }
        var next = settings; edit(&next)
        do { try next.validate() } catch { self.error = error.localizedDescription; return }
        let breaksChanged = next.breaksEnabled != settings.breaksEnabled || next.workMinutes != settings.workMinutes || next.restSeconds != settings.restSeconds
        settings = next
        if breaksChanged {
            if next.breaksEnabled { clock.start(now: ProcessInfo.processInfo.systemUptime, workSeconds: next.workMinutes * 60) }
            else { clock.stop() }
            hideBreak?(); syncBreak()
        }
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.save() }; pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: save)
        pendingApply?.cancel()
        let apply = DispatchWorkItem { [weak self] in self?.applyNow() }; pendingApply = apply
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: apply)
        configureTimer(); changed?()
    }

    func preset(_ preset: Preset) { update { $0.manual = preset.values; $0.mode = .manual } }
    func adjust(temperature: Double = 0, brightness: Double = 0) {
        let current = effective.values
        update {
            $0.mode = .manual
            $0.manual = DisplayValues(temperature: min(6500, max(1200, current.temperature + temperature)),
                                      brightness: min(100, max(20, current.brightness + brightness)))
        }
    }
    func pause(minutes: Double? = nil) {
        pausedUntil = minutes.map { Date().addingTimeInterval($0 * 60) }
        pausedIndefinitely = minutes == nil
        pendingApply?.cancel(); applyNow(); configureTimer(); changed?()
    }
    func resume() { pausedUntil = nil; pausedIndefinitely = false; applyNow(); configureTimer(); changed?() }
    func togglePause() { isPaused ? resume() : pause() }

    func refreshDisplays() {
        do { try displayController.refresh(); displays = displayController.info }
        catch { self.error = error.localizedDescription }
        applyNow()
    }

    func applyNow() {
        guard !shuttingDown else { return }
        do {
            if settings.enabled && !isPaused && !sleeping {
                let value = effective
                try displayController.apply(value.values, preferences: settings.displays)
                let supported = displayController.info.contains { $0.supported && settings.displays[$0.id]?.enabled != false }
                status = supported ? "\(value.phase) · \(Int(value.values.temperature)) K · \(Int(value.values.brightness))%" : "No enabled, supported displays"
            } else {
                try displayController.restore()
                status = isPaused ? "Paused · original display colors" : "Off · original display colors"
            }
            displays = displayController.info
        } catch {
            self.error = error.localizedDescription
            status = "Display operation failed · see details"
            displays = displayController.info
        }
        changed?()
    }

    func willSleep() {
        sleeping = true
        pendingApply?.cancel()
        clock.pause(now: ProcessInfo.processInfo.systemUptime)
        hideBreak?(); applyNow(); timer?.invalidate(); syncBreak()
    }
    func didWake() {
        sleeping = false
        // A break is for active work. Start a fresh work interval after sleep/unlock.
        if settings.breaksEnabled { clock.start(now: ProcessInfo.processInfo.systemUptime, workSeconds: settings.workMinutes * 60) }
        refreshDisplays(); syncBreak(); configureTimer()
    }
    func takeBreak() {
        guard settings.breaksEnabled else { return }
        clock.rest(now: ProcessInfo.processInfo.systemUptime, seconds: settings.restSeconds)
        syncBreak(); showBreak?(); configureTimer()
    }
    func postponeBreak() {
        clock.postpone(now: ProcessInfo.processInfo.systemUptime)
        hideBreak?(); syncBreak(); configureTimer()
    }
    func finishBreak() {
        clock.start(now: ProcessInfo.processInfo.systemUptime, workSeconds: settings.workMinutes * 60)
        hideBreak?(); syncBreak(); configureTimer()
    }
    func toggleBreakPause() {
        let now = ProcessInfo.processInfo.systemUptime
        if clock.phase == .paused { clock.resume(now: now); if clock.phase == .resting { showBreak?() } }
        else { clock.pause(now: now); hideBreak?() }
        syncBreak(); configureTimer()
    }
    private func syncBreak() {
        breakPhase = clock.phase; breakRemaining = Int(ceil(clock.remaining))
    }
    private func configureTimer() {
        timer?.invalidate(); timer = nil
        guard !sleeping, !shuttingDown else { return }
        let tickingBreak = clock.phase == .working || clock.phase == .resting
        guard tickingBreak || pausedUntil != nil || (settings.enabled && !isPaused && settings.mode == .scheduled) else { return }
        let interval = tickingBreak || pausedUntil != nil ? 1.0 : 5.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func tick() {
        if let until = pausedUntil, until <= Date() { resume() }
        let before = clock.phase
        clock.tick(now: ProcessInfo.processInfo.systemUptime, workSeconds: settings.workMinutes * 60, restSeconds: settings.restSeconds)
        syncBreak()
        if before != clock.phase {
            if clock.phase == .resting { showBreak?() } else { hideBreak?() }
        }
        if settings.enabled && settings.mode == .scheduled && !isPaused { applyNow() }
    }

    private func save() {
        guard !storageBlocked else { return }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        } catch { self.error = "Settings could not be saved: \(error.localizedDescription)" }
    }
    func dismissError() { error = nil }
    func reportError(_ message: String) { error = message }
    func resetUnreadableSettings() {
        do {
            let backup = settingsURL.deletingPathExtension().appendingPathExtension("backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: settingsURL, to: backup)
            storageBlocked = false; error = nil; settings = Settings(); save(); applyNow(); configureTimer()
        } catch { self.error = "Could not back up existing settings: \(error.localizedDescription)" }
    }
    func exportSettings() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "cornea-native-settings.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(settings).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 1_000_000 else { throw SettingsError.invalid("Settings file is too large.") }
            let imported = try JSONDecoder().decode(Settings.self, from: data); try imported.validate()
            update { $0 = imported }
        } catch { self.error = "Import rejected: \(error.localizedDescription)" }
    }
    func shutdown() {
        shuttingDown = true; timer?.invalidate(); pendingApply?.cancel(); pendingSave?.cancel()
        save(); displayController.shutdown()
    }
}
