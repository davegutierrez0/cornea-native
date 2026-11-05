import SwiftUI
import CorneaCore
import ServiceManagement

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var page = "Display"
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "sun.max.fill").font(.system(size: 30)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cornea Native").font(.title2.bold())
                    Text(model.status).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("display-status")
                }
                Spacer()
                Toggle("Enable", isOn: binding(\.enabled)).toggleStyle(.switch).disabled(model.storageBlocked)
            }.padding(24)
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.callout).textSelection(.enabled)
                    Spacer()
                    if model.storageBlocked { Button("Back up and reset") { model.resetUnreadableSettings() } }
                    else { Button("Dismiss") { model.dismissError() } }
                }.padding(12).background(.orange.opacity(0.12)).padding(.horizontal, 24).padding(.bottom, 12)
            }
            Picker("Settings page", selection: $page) {
                ForEach(["Display", "Schedule", "Monitors", "Breaks", "General"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch page {
                    case "Display": displayPage
                    case "Schedule": schedulePage
                    case "Monitors": monitorsPage
                    case "Breaks": breaksPage
                    default: generalPage
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.disabled(model.storageBlocked)
            Divider()
            HStack {
                Text("Apple Silicon native · local only").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit and restore colors") { NSApplication.shared.terminate(nil) }
            }.padding(16)
        }.frame(width: 660, height: 650)
    }
    private func binding<T>(_ key: WritableKeyPath<CorneaCore.Settings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: key] }, set: { value in model.update { $0[keyPath: key] = value } })
    }
    private func valueBinding(_ key: WritableKeyPath<CorneaCore.Settings, DisplayValues>) -> Binding<DisplayValues> { binding(key) }

    private var displayPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Picker("Control", selection: binding(\.mode)) {
                    Text("Manual").tag(ControlMode.manual)
                    Text("Automatic schedule").tag(ControlMode.scheduled)
                }.pickerStyle(.segmented)
            }
            if model.settings.mode == .manual {
                ValuesEditor(title: "Screen appearance", values: valueBinding(\.manual))
                HStack {
                    ForEach(Preset.allCases) { preset in Button(preset.rawValue) { model.preset(preset) } }
                }
            } else {
                GroupBox("Current schedule target") {
                    HStack {
                        Text(model.effective.phase)
                        Spacer()
                        Text("\(Int(model.effective.values.temperature)) K · \(Int(model.effective.values.brightness))%")
                            .monospacedDigit()
                    }.padding(10)
                }
                Text("Set day, night, and optional bedtime values in Schedule. Individual monitor overrides remain fixed.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if model.isPaused {
                    Button("Resume display controls") { model.resume() }.buttonStyle(.borderedProminent)
                    if let until = model.pausedUntil { Text("Until \(until.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary) }
                } else {
                    Menu("Pause and restore colors") {
                        Button("For 15 minutes") { model.pause(minutes: 15) }
                        Button("For 1 hour") { model.pause(minutes: 60) }
                        Button("Until resumed") { model.pause() }
                    }
                }
            }
            Text("Brightness dims the image in software. It does not change the monitor’s backlight or PWM. Keep Night Shift, True Tone, and other color-control apps off while Cornea Native controls your display.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Pause and Quit restore the calibration captured when Cornea Native connected to each display. A small recovery process also restores it if the app crashes.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private var schedulePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Picker("Schedule", selection: Binding(get: { model.settings.schedule }, set: { kind in
                model.update { $0.schedule = kind; if kind == .sun { $0.locationConfigured = true } }
            })) {
                Text("Fixed local times").tag(ScheduleKind.clock)
                Text("Sunrise and sunset").tag(ScheduleKind.sun)
            }.pickerStyle(.segmented)
            if model.settings.schedule == .clock {
                HStack { TimeEditor(title: "Day starts", minute: binding(\.dayMinute)); Spacer(); TimeEditor(title: "Night starts", minute: binding(\.nightMinute)) }
            } else {
                HStack {
                    TextField("Latitude", value: binding(\.latitude), format: .number).textFieldStyle(.roundedBorder)
                    TextField("Longitude", value: binding(\.longitude), format: .number).textFieldStyle(.roundedBorder)
                }
                Text("Enter your coordinates (north/east positive). No location request or network lookup. Times are approximate; your Mac’s time zone applies. Polar day/night uses the corresponding profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ValuesEditor(title: "Day", values: valueBinding(\.day))
            ValuesEditor(title: "Night", values: valueBinding(\.night))
            Toggle("Use a bedtime profile", isOn: binding(\.useSleep))
            if model.settings.useSleep {
                TimeEditor(title: "Bedtime starts", minute: binding(\.sleepMinute))
                ValuesEditor(title: "Bedtime", values: valueBinding(\.sleep))
            }
            HStack {
                Text("Transition")
                Slider(value: binding(\.transitionMinutes), in: 0...120, step: 5)
                Text("\(Int(model.settings.transitionMinutes)) min").monospacedDigit().frame(width: 60)
            }
            Text("Transitions begin at each scheduled time. The next event limits their duration. Choose Automatic schedule on the Display page to use these settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var monitorsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Connected displays").font(.headline); Spacer(); Button("Refresh displays") { model.refreshDisplays() } }
            if model.displays.isEmpty { Text("No connected displays were found.").foregroundStyle(.secondary) }
            ForEach(model.displays) { display in
                let p = model.settings.displays[display.id] ?? DisplayPreference()
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(display.name).font(.headline); Spacer(); Toggle("Control this display", isOn: displayBinding(display.id, \.enabled)).disabled(!display.supported) }
                        Text(display.status).font(.caption).foregroundStyle(.secondary)
                        if display.supported && p.enabled {
                            Toggle("Use fixed values for this display", isOn: displayBinding(display.id, \.useOverride))
                            if p.useOverride { ValuesEditor(title: "Override", values: displayBinding(display.id, \.values)) }
                        }
                    }.padding(8)
                }
            }
            Text("Settings follow the display UUID, not its connection order. Mirrored displays share their source’s settings. Excluded displays return to their original calibration.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func displayBinding<T>(_ id: String, _ key: WritableKeyPath<DisplayPreference, T>) -> Binding<T> {
        Binding(get: { (model.settings.displays[id] ?? DisplayPreference())[keyPath: key] }, set: { value in
            model.update { var p = $0.displays[id] ?? DisplayPreference(); p[keyPath: key] = value; $0.displays[id] = p }
        })
    }
    private var breaksPage: some View {
        VStack(alignment: .leading, spacing: 22) {
            Toggle("Enable break reminders", isOn: binding(\.breaksEnabled))
            HStack {
                Text("Work for")
                TextField("Work minutes", value: binding(\.workMinutes), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("minutes, then rest for")
                TextField("Rest seconds", value: binding(\.restSeconds), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                Text("seconds")
            }
            if model.settings.breaksEnabled {
                Text(breakTitle).font(.title2).monospacedDigit()
                HStack {
                    Button(model.breakPhase == .paused ? "Resume timer" : "Pause timer") { model.toggleBreakPause() }
                    Button("Take a break now") { model.takeBreak() }
                }
            }
            Text("A small reminder window appears when it is time to rest. It never blocks your keyboard or locks the screen. You can postpone it for five minutes or skip it. Work time restarts after sleep or session unlock.")
                .foregroundStyle(.secondary)
        }
    }
    private var breakTitle: String {
        let label = model.breakPhase == .resting ? "Rest" : model.breakPhase == .paused ? "Paused" : "Next break"
        return "\(label) · \(model.breakRemaining / 60):\(String(format: "%02d", model.breakRemaining % 60))"
    }
    private var generalPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Keyboard shortcuts").font(.headline)
            Toggle("Enable global shortcuts", isOn: binding(\.shortcutsEnabled))
            Grid(alignment: .leading, horizontalSpacing: 30, verticalSpacing: 10) {
                GridRow { Text("Pause / resume colors"); Text("⌃⌥⌘P") }
                GridRow { Text("Warmer / cooler"); Text("⌃⌥⌘← / →") }
                GridRow { Text("Dimmer / brighter"); Text("⌃⌥⌘↓ / ↑") }
            }.foregroundStyle(.secondary)
            Text("These shortcuts work without Accessibility or Input Monitoring access. A conflict is reported instead of taking another app’s shortcut.").font(.caption).foregroundStyle(.secondary)
            Divider()
            LoginItemControl()
            HStack {
                Button("Export settings…") { model.exportSettings() }
                Button("Import settings…") { model.importSettings() }
            }
            Text("Imports accept Cornea Native JSON settings. Settings from other apps are not migrated or modified.").font(.caption).foregroundStyle(.secondary)
            Text("No telemetry, account, network connection, screen recording, or private display API is used.").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ValuesEditor: View {
    let title: String
    @Binding var values: DisplayValues
    var body: some View {
        GroupBox(title) {
            VStack(spacing: 14) {
                HStack {
                    Text("Temperature").frame(width: 90, alignment: .leading)
                    Slider(value: $values.temperature, in: 1200...6500, step: 100).accessibilityLabel("\(title) temperature")
                    Text("\(Int(values.temperature)) K").monospacedDigit().frame(width: 68, alignment: .trailing)
                }
                HStack {
                    Text("Brightness").frame(width: 90, alignment: .leading)
                    Slider(value: $values.brightness, in: 20...100, step: 1).accessibilityLabel("\(title) brightness")
                    Text("\(Int(values.brightness))%").monospacedDigit().frame(width: 68, alignment: .trailing)
                }
            }.padding(12)
        }
    }
}
struct TimeEditor: View {
    let title: String
    @Binding var minute: Int
    var body: some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
}
struct LoginItemControl: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Open at login", isOn: Binding(get: { enabled }, set: { wanted in
                do {
                    if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    enabled = SMAppService.mainApp.status == .enabled
                    message = SMAppService.mainApp.status == .requiresApproval ? "Approve Cornea Native in System Settings → General → Login Items." : nil
                } catch { message = error.localizedDescription }
            }))
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct BreakView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "eye").font(.system(size: 38)).foregroundStyle(.orange)
            Text("Give your eyes a break").font(.title2.bold())
            Text("Look away from the screen and relax.").foregroundStyle(.secondary)
            Text("\(model.breakRemaining) seconds").font(.title.monospacedDigit())
            HStack {
                Button("Postpone 5 minutes") { model.postponeBreak() }
                Button("Skip break") { model.finishBreak() }
            }
        }.padding(32).frame(width: 380)
    }
}
