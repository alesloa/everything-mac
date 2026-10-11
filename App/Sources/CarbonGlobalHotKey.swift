import Carbon

@MainActor
final class CarbonGlobalHotKey: GlobalHotKeyRegistering {
    var onTrigger: (@MainActor () -> Void)?
    private var native = NativeState()
    private static let identifier = EventHotKeyID(signature: 0x454D4143, id: 1)

    private struct NativeState: @unchecked Sendable {
        var registration: EventHotKeyRef?
        var handler: EventHandlerRef?
    }

    func replace(with binding: GlobalShortcutBinding?) -> OSStatus {
        if let registration = native.registration {
            let status = UnregisterEventHotKey(registration)
            guard status == noErr else { return status }
            native.registration = nil
        }
        guard let binding else { return noErr }
        guard binding.isValid else { return OSStatus(paramErr) }
        if native.handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    var identifier = EventHotKeyID()
                    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                                   EventParamType(typeEventHotKeyID), nil,
                                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                    guard status == noErr else { return status }
                    guard identifier.signature == CarbonGlobalHotKey.identifier.signature,
                          identifier.id == CarbonGlobalHotKey.identifier.id else { return OSStatus(eventNotHandledErr) }
                    let owner = Unmanaged<CarbonGlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                    owner.onTrigger?()
                    return noErr
                }
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &native.handler)
            guard status == noErr else { return status }
        }
        return RegisterEventHotKey(binding.keyCode, binding.modifiers, Self.identifier,
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &native.registration)
    }

    deinit {
        if let registration = native.registration { UnregisterEventHotKey(registration) }
        if let handler = native.handler { RemoveEventHandler(handler) }
    }
}
