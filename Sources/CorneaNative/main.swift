import AppKit
import SwiftUI
import CorneaCore

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--recovery-watchdog") {
    runRecoveryWatchdog()
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    let hotkeys = Hotkeys()
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var breakWindow: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var signals: [DispatchSourceSignal] = []
    private var reconfigure: DispatchWorkItem?
    private var shortcutsSetting: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appMenu = NSMenuItem(); appMenu.submenu = NSMenu(title: "Cornea Native")
        appMenu.submenu?.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.submenu?.addItem(.separator())
        appMenu.submenu?.addItem(withTitle: "Quit Cornea Native", action: #selector(quit), keyEquivalent: "q").target = self
        menu.addItem(appMenu)
        let edit = NSMenuItem(); edit.submenu = NSMenu(title: "Edit")
        for (name, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.submenu?.addItem(withTitle: name, action: action, keyEquivalent: key)
        }
        menu.addItem(edit); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Cornea Native")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 650), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Cornea Native"; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView(model: model)); window.center()
        model.changed = { [weak self] in self?.updateMenu() }
        model.showBreak = { [weak self] in self?.showBreak() }
        model.hideBreak = { [weak self] in self?.breakWindow?.orderOut(nil) }
        hotkeys.action = { [weak self] key in
            guard let model = self?.model else { return }
            switch key {
            case 0: model.togglePause()
            case 1: model.adjust(temperature: -100)
            case 2: model.adjust(temperature: 100)
            case 3: model.adjust(brightness: -5)
            case 4: model.adjust(brightness: 5)
            default: break
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.willSleep() }
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.didWake() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconfigure?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.model.refreshDisplays() }
                self.reconfigure = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
            }
        })
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }; source.resume(); signals.append(source)
        }
        model.start()
        updateMenu()
        if !CommandLine.arguments.contains("--background") { window.orderFront(nil) }
    }
    private func updateMenu() {
        guard statusItem != nil else { return }
        let isActive = model.settings.enabled && !model.isPaused
        statusItem.button?.image = NSImage(systemSymbolName: isActive ? "sun.max.fill" : "sun.max", accessibilityDescription: "Cornea Native")
        statusItem.button?.toolTip = "Cornea Native · \(model.status)"
        let menu = NSMenu()
        let status = NSMenuItem(title: model.status, action: nil, keyEquivalent: ""); status.isEnabled = false; menu.addItem(status)
        menu.addItem(.separator())
        let toggle = menu.addItem(withTitle: model.settings.enabled ? "Turn off and restore colors" : "Enable display controls", action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(withTitle: model.isPaused ? "Resume display controls" : "Pause until resumed", action: #selector(togglePause), keyEquivalent: "").target = self
        if !model.isPaused { menu.addItem(withTitle: "Pause for 15 minutes", action: #selector(pause15), keyEquivalent: "").target = self }
        let presets = NSMenuItem(title: "Presets", action: nil, keyEquivalent: ""); presets.submenu = NSMenu()
        for (index, preset) in Preset.allCases.enumerated() {
            let item = presets.submenu!.addItem(withTitle: preset.rawValue, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.tag = index; item.target = self
        }
        menu.addItem(presets)
        if model.settings.breaksEnabled { menu.addItem(withTitle: "Take a break now", action: #selector(takeBreak), keyEquivalent: "").target = self }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit and restore colors", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        if shortcutsSetting != model.settings.shortcutsEnabled {
            shortcutsSetting = model.settings.shortcutsEnabled
            if let message = hotkeys.configure(enabled: model.settings.shortcutsEnabled) { model.reportError(message) }
        }
    }
    private func showBreak() {
        if breakWindow == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 444, height: 300), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Cornea Native · Break"; panel.level = .floating; panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: BreakView(model: model)); panel.center(); breakWindow = panel
        }
        breakWindow?.orderFrontRegardless()
    }
    @objc private func showSettings() { window.makeKeyAndOrderFront(nil) }
    @objc private func toggleEnabled() { model.update { $0.enabled.toggle() } }
    @objc private func togglePause() { model.togglePause() }
    @objc private func pause15() { model.pause(minutes: 15) }
    @objc private func takeBreak() { model.takeBreak() }
    @objc private func selectPreset(_ sender: NSMenuItem) { model.preset(Preset.allCases[sender.tag]) }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        reconfigure?.cancel(); hotkeys.clear(); model.shutdown()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
