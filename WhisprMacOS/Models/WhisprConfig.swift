import Foundation
import Carbon.HIToolbox

enum RecordingMode: String, CaseIterable, Codable {
    case hold = "Hold to Record"
    case toggle = "Toggle Recording"
}

struct WhisprConfig: Codable {
    var modelName: String = "base.en"
    var language: String = "en"
    var recordingMode: RecordingMode = .hold
    var hotkeyKeyCode: UInt16 = UInt16(kVK_RightOption)
    var hotkeyModifiers: UInt = 0
    var playSounds: Bool = true
    var autoCapitalize: Bool = true
    var convertPunctuation: Bool = true
    var removeFiller: Bool = false
    var clipboardRestoreDelay: TimeInterval = 0.2
    var useStreaming: Bool = true
    var llmEnabled: Bool = false
    var launchAtLogin: Bool = false
    var dictionaryEntries: [DictionaryEntry] = []
    var historyEnabled: Bool = true

    static let `default` = WhisprConfig()

    private static let storageKey = "whispr_config"

    static func load() -> WhisprConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(WhisprConfig.self, from: data) else {
            return .default
        }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: WhisprConfig.storageKey)
        }
    }
}

