import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

struct SettingsView: View {
    @State private var config = WhisprConfig.load()
    @State private var showingHotkeyCapture = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }

            textTab
                .tabItem { Label("Text", systemImage: "textformat") }

            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }

            featuresTab
                .tabItem { Label("Features", systemImage: "sparkles") }
        }
        .frame(width: 480, height: 420)
        .onChange(of: config.playSounds) { _, _ in config.save() }
        .onChange(of: config.autoCapitalize) { _, _ in config.save() }
        .onChange(of: config.convertPunctuation) { _, _ in config.save() }
        .onChange(of: config.removeFiller) { _, _ in config.save() }
        .onChange(of: config.recordingMode) { _, _ in config.save() }
        .onChange(of: config.useStreaming) { _, _ in config.save() }
        .onChange(of: config.llmEnabled) { _, _ in config.save() }
        .onChange(of: config.historyEnabled) { _, _ in config.save() }
        .onChange(of: config.launchAtLogin) { _, newValue in
            config.save()
            setLaunchAtLogin(newValue)
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Application") {
                Toggle("Play sounds", isOn: $config.playSounds)
                Toggle("Launch at login", isOn: $config.launchAtLogin)
                Toggle("Save transcription history", isOn: $config.historyEnabled)
            }

            Section("Hotkey") {
                Picker("Mode", selection: $config.recordingMode) {
                    ForEach(RecordingMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                HStack {
                    Text("Key")
                    Spacer()
                    Text(KeyCodes.displayName(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                        .font(.system(.body, design: .monospaced))
                }
            }

            Section("Model") {
                Picker("Model", selection: $config.modelName) {
                    Text("tiny.en (75 MB, fastest)").tag("tiny.en")
                    Text("base.en (142 MB, recommended)").tag("base.en")
                    Text("small.en (466 MB, accurate)").tag("small.en")
                    Text("medium.en (1.5 GB, very accurate)").tag("medium.en")
                }
                .onChange(of: config.modelName) { _, _ in config.save() }

                Picker("Language", selection: $config.language) {
                    Text("English").tag("en")
                    Text("Auto-detect").tag("auto")
                }
                .onChange(of: config.language) { _, _ in config.save() }

                Text("Use .en models for English. base.en is recommended for real-time use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Text("Microphone")
                    Spacer()
                    if Permissions.checkMicrophone() {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Granted").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Grant") {
                            Task { _ = await Permissions.requestMicrophone() }
                        }
                    }
                }
                HStack {
                    Text("Accessibility")
                    Spacer()
                    if Permissions.checkAccessibility() {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Granted").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                            Text("Optional — enables auto-paste").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
    }

    // MARK: - Text Processing

    private var textTab: some View {
        Form {
            Section("Processing") {
                Toggle("Auto-capitalize sentences", isOn: $config.autoCapitalize)
                Toggle("Convert spoken punctuation", isOn: $config.convertPunctuation)
                Toggle("Remove filler words (um, uh, like)", isOn: $config.removeFiller)
            }

            Section("Clipboard") {
                HStack {
                    Text("Restore delay")
                    Spacer()
                    Text("\(Int(config.clipboardRestoreDelay * 1000))ms")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Context Detection") {
                Text("Whispr detects the active app and adjusts formatting — code editors preserve casing, chat apps remove trailing periods, emails add them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Dictionary

    private var dictionaryTab: some View {
        Form {
            Section {
                Text("Add words and their correct spellings. Whispr will replace spoken forms with the correct version after transcription and hint the speech model for better recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Terms") {
                if config.dictionaryEntries.isEmpty {
                    Text("No custom terms added yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach($config.dictionaryEntries) { $entry in
                        HStack(spacing: 8) {
                            TextField("Spoken", text: $entry.spoken)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            TextField("Replacement", text: $entry.replacement)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button {
                                config.dictionaryEntries.removeAll { $0.id == entry.id }
                                config.save()
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    config.dictionaryEntries.append(DictionaryEntry(spoken: "", replacement: ""))
                    config.save()
                } label: {
                    Label("Add Term", systemImage: "plus")
                }

                if !config.dictionaryEntries.isEmpty {
                    Button("Save Changes") {
                        config.save()
                    }
                    .font(.caption)
                }
            }
        }
        .padding()
    }

    // MARK: - Features

    private var featuresTab: some View {
        Form {
            Section("Streaming") {
                Toggle("Enable streaming transcription", isOn: $config.useStreaming)
                Text("Shows words live as you speak in a floating overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("LLM Post-Processing") {
                Toggle("Enable LLM cleanup", isOn: $config.llmEnabled)
                Text("Uses a local LLM (Qwen3-1.7B) to clean up transcriptions. Requires ~1GB download, runs entirely on-device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if config.llmEnabled {
                Section("Voice Commands") {
                    Text("Start your dictation with a command:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\"Fix grammar\" — corrects selected text")
                        Text("\"Make professional\" — formal rewrite")
                        Text("\"Make casual\" — informal rewrite")
                        Text("\"Summarize\" — condenses selected text")
                        Text("\"Translate to [language]\" — translates")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    // MARK: - Launch at Login

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            NSLog("[Whispr] Launch at login: \(enabled)")
        } catch {
            NSLog("[Whispr] Failed to set launch at login: \(error.localizedDescription)")
        }
    }
}
