import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id = UUID()
    let rawText: String
    let processedText: String
    let appContext: String
    let timestamp: Date
}

final class TranscriptionHistory {
    static let shared = TranscriptionHistory()

    private let maxEntries = 1000
    private let fileURL: URL

    private(set) var entries: [HistoryEntry] = []

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sottoDir = appSupport.appendingPathComponent("Sotto", isDirectory: true)

        // One-time migration of the whole data directory from a previous app name.
        // A same-volume rename is atomic and instant, so the ~140MB+ of downloaded
        // models carry over without a copy or re-download.
        Self.migrateLegacyDataDirectory(appSupport: appSupport, sottoDir: sottoDir)

        try? FileManager.default.createDirectory(at: sottoDir, withIntermediateDirectories: true)
        self.fileURL = sottoDir.appendingPathComponent("history.json")

        load()
    }

    /// Rename ~/Library/Application Support/{Sona,Murmur,Whispr}/ → Sotto/ on first launch
    /// under the new name. Newest legacy name wins; older ones are left untouched.
    private static func migrateLegacyDataDirectory(appSupport: URL, sottoDir: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: sottoDir.path) else { return }

        for legacyName in ["Sona", "Murmur", "Whispr"] {
            let legacyDir = appSupport.appendingPathComponent(legacyName, isDirectory: true)
            guard fm.fileExists(atPath: legacyDir.path) else { continue }
            do {
                try fm.moveItem(at: legacyDir, to: sottoDir)
                NSLog("[Sotto] Migrated data directory from \(legacyName)")
            } catch {
                NSLog("[Sotto] Data migration from \(legacyName) failed: \(error.localizedDescription)")
            }
            break
        }

        // Carry over UserDefaults flags. (No-op if the bundle identifier also changed,
        // since that moves the defaults domain — acceptable, the user just re-onboards.)
        let keyMap: [(old: String, new: String)] = [
            ("sona_onboarding_complete", "sotto_onboarding_complete"),
            ("sona_accessibility_prompted", "sotto_accessibility_prompted"),
            ("murmur_onboarding_complete", "sotto_onboarding_complete"),
            ("murmur_accessibility_prompted", "sotto_accessibility_prompted"),
            ("whispr_onboarding_complete", "sotto_onboarding_complete"),
            ("whispr_accessibility_prompted", "sotto_accessibility_prompted"),
        ]
        for key in keyMap where UserDefaults.standard.object(forKey: key.old) != nil
            && UserDefaults.standard.object(forKey: key.new) == nil {
            UserDefaults.standard.set(UserDefaults.standard.bool(forKey: key.old), forKey: key.new)
            UserDefaults.standard.removeObject(forKey: key.old)
        }
    }

    func add(rawText: String, processedText: String, appContext: AppContext) {
        let entry = HistoryEntry(
            rawText: rawText,
            processedText: processedText,
            appContext: appContext.rawValue,
            timestamp: Date()
        )
        entries.insert(entry, at: 0)

        // Cap at maxEntries (FIFO)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }

        save()
    }

    func clear() {
        entries = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try JSONDecoder().decode([HistoryEntry].self, from: data)
        } catch {
            NSLog("[Sotto] Failed to load history: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Sotto] Failed to save history: \(error.localizedDescription)")
        }
    }
}
