import Carbon

@MainActor
final class Hotkeys {
    private var registrations: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    var action: ((UInt32) -> Void)?
    private var enabled = false
    private let signature: OSType = 0x434F524E

    func configure(enabled: Bool) -> String? {
        guard self.enabled != enabled else { return nil }
        clear()
        guard enabled else { return nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr else { return result }
            let owner = Unmanaged<Hotkeys>.fromOpaque(context).takeUnretainedValue()
            let key = id.id
            MainActor.assumeIsolated { owner.action?(key) }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return "Global shortcuts could not be installed (\(status))." }
        let keys = [kVK_ANSI_P, kVK_LeftArrow, kVK_RightArrow, kVK_DownArrow, kVK_UpArrow]
        for (index, key) in keys.enumerated() {
            var reference: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey | cmdKey),
                                             EventHotKeyID(signature: signature, id: UInt32(index)),
                                             GetApplicationEventTarget(), 0, &reference)
            guard result == noErr, let reference else { clear(); return "A global shortcut is unavailable or in use (\(result)). Disable shortcuts or resolve the conflict." }
            registrations.append(reference)
        }
        self.enabled = true
        return nil
    }
    func clear() {
        for registration in registrations { UnregisterEventHotKey(registration) }
        registrations.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil; enabled = false
    }
}
