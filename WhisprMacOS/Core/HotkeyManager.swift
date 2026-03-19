import AppKit
import Carbon.HIToolbox

final class HotkeyManager {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var flagsMonitor: Any?
    private var isModifierKeyDown = false

    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?

    private var targetKeyCode: UInt16
    private var targetModifiers: UInt
    private var mode: RecordingMode
    private var isToggled = false

    init(keyCode: UInt16 = UInt16(kVK_RightOption), modifiers: UInt = 0, mode: RecordingMode = .hold) {
        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers
        self.mode = mode
    }

    func start() {
        stop()

        // For modifier-only keys (Option, Command, Shift, Control), use flagsChanged
        let isModifierKey = isModifierOnlyKey(targetKeyCode)

        if isModifierKey {
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.handleFlagsChanged(event)
            }
        } else {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKeyEvent(event)
            }
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                self?.handleKeyEvent(event)
                return event
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        globalMonitor = nil
        localMonitor = nil
        flagsMonitor = nil
        isModifierKeyDown = false
        isToggled = false
    }

    func updateHotkey(keyCode: UInt16, modifiers: UInt = 0, mode: RecordingMode) {
        self.targetKeyCode = keyCode
        self.targetModifiers = modifiers
        self.mode = mode
        start() // Restart monitors with new config
    }

    // MARK: - Event Handling

    private func handleKeyEvent(_ event: NSEvent) {
        guard event.keyCode == targetKeyCode else { return }

        // Check modifiers match (mask out device-dependent bits)
        let currentMods = event.modifierFlags.rawValue & 0x00FF0000
        guard currentMods == targetModifiers || targetModifiers == 0 else { return }

        switch mode {
        case .hold:
            if event.type == .keyDown && !event.isARepeat {
                onRecordingStart?()
            } else if event.type == .keyUp {
                onRecordingStop?()
            }
        case .toggle:
            if event.type == .keyDown && !event.isARepeat {
                isToggled.toggle()
                if isToggled {
                    onRecordingStart?()
                } else {
                    onRecordingStop?()
                }
            }
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let isPressed = isTargetModifierPressed(event)

        switch mode {
        case .hold:
            if isPressed && !isModifierKeyDown {
                isModifierKeyDown = true
                onRecordingStart?()
            } else if !isPressed && isModifierKeyDown {
                isModifierKeyDown = false
                onRecordingStop?()
            }
        case .toggle:
            if isPressed && !isModifierKeyDown {
                isModifierKeyDown = true
                isToggled.toggle()
                if isToggled {
                    onRecordingStart?()
                } else {
                    onRecordingStop?()
                }
            } else if !isPressed {
                isModifierKeyDown = false
            }
        }
    }

    private func isTargetModifierPressed(_ event: NSEvent) -> Bool {
        switch targetKeyCode {
        case UInt16(kVK_RightOption), UInt16(kVK_Option):
            return event.modifierFlags.contains(.option)
        case UInt16(kVK_RightCommand), UInt16(kVK_Command):
            return event.modifierFlags.contains(.command)
        case UInt16(kVK_RightShift), UInt16(kVK_Shift):
            return event.modifierFlags.contains(.shift)
        case UInt16(kVK_RightControl), UInt16(kVK_Control):
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func isModifierOnlyKey(_ keyCode: UInt16) -> Bool {
        let modifierKeys: Set<UInt16> = [
            UInt16(kVK_Option), UInt16(kVK_RightOption),
            UInt16(kVK_Command), UInt16(kVK_RightCommand),
            UInt16(kVK_Shift), UInt16(kVK_RightShift),
            UInt16(kVK_Control), UInt16(kVK_RightControl),
        ]
        return modifierKeys.contains(keyCode)
    }
}
