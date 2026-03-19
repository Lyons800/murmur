import SwiftUI

@main
struct WhisprMacOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appDelegate: appDelegate)
        } label: {
            Image(systemName: appDelegate.menuBarIcon)
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("History", id: "history") {
            HistoryView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(appDelegate.appState.state.statusText)
            .font(.caption)

        if let last = appDelegate.appState.lastTranscription, !last.isEmpty {
            Divider()
            let preview = String(last.prefix(60)) + (last.count > 60 ? "..." : "")
            Text("Last: \(preview)")
                .font(.caption)
        }

        Divider()

        let config = WhisprConfig.load()
        let hotkeyName = KeyCodes.displayName(keyCode: config.hotkeyKeyCode, modifiers: config.hotkeyModifiers)
        Text("Hotkey: \(hotkeyName)")
            .font(.caption)
        Text("Model: \(config.modelName)")
            .font(.caption)

        Divider()

        Button("History...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        .keyboardShortcut("h")

        Button("Settings...") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "settings")
        }
        .keyboardShortcut(",")

        Button("Quit Whispr") {
            appDelegate.shutdown()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, Observable {
    let appState = AppState()
    let audioRecorder = AudioRecorder()
    let textInserter = TextInserter()
    let hotkeyManager: HotkeyManager
    let transcriptionEngine: TranscriptionEngine
    let overlay = TranscriptionOverlay()
    let llmProcessor = LLMProcessor()

    var menuBarIcon: String = "waveform"
    private var streamingTask: Task<Void, Error>?
    private var onboardingWindow: NSWindow?

    override init() {
        let config = WhisprConfig.load()
        self.transcriptionEngine = TranscriptionEngine(modelName: config.modelName)
        self.hotkeyManager = HotkeyManager(
            keyCode: config.hotkeyKeyCode,
            modifiers: config.hotkeyModifiers,
            mode: config.recordingMode
        )
        super.init()
    }

    private static let onboardingCompleteKey = "whispr_onboarding_complete"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check current permission state without prompting
        appState.hasMicrophonePermission = Permissions.checkMicrophone()
        appState.hasAccessibilityPermission = Permissions.checkAccessibility()

        let onboardingDone = UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey)

        if !onboardingDone || !appState.hasMicrophonePermission {
            // Show onboarding — permissions are requested there by user action
            NSLog("[Whispr] Showing onboarding...")
            showOnboardingWindow()
        } else {
            // Already onboarded with mic permission — go straight to loading
            Task { await loadModelAndStart() }
        }
    }

    // MARK: - Onboarding Window

    private func showOnboardingWindow() {
        let onboardingView = OnboardingView { [weak self] in
            self?.completeOnboarding()
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whispr"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        self.onboardingWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Called from OnboardingView when the user taps "Get Started"
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        appState.hasMicrophonePermission = Permissions.checkMicrophone()
        appState.hasAccessibilityPermission = Permissions.checkAccessibility()

        onboardingWindow?.close()
        onboardingWindow = nil

        Task { await loadModelAndStart() }
    }

    func shutdown() {
        hotkeyManager.stop()
        streamingTask?.cancel()
        audioRecorder.shutdown()
    }

    // MARK: - Initialization

    private func loadModelAndStart() async {
        NSLog("[Whispr] Initializing...")

        // Load Whisper model (no permission prompts here)
        NSLog("[Whispr] Loading model: \(transcriptionEngine.modelName)...")
        appState.state = .loading(progress: 0)

        do {
            try await transcriptionEngine.loadModel { progress in
                Task { @MainActor [weak self] in
                    self?.appState.state = .loading(progress: progress)
                    NSLog("[Whispr] Model download: \(Int(progress * 100))%")
                }
            }
            appState.state = .ready
            NSLog("[Whispr] Model loaded. Ready!")
        } catch {
            appState.state = .error(error.localizedDescription)
            NSLog("[Whispr] Model load failed: \(error.localizedDescription)")
            return
        }

        // Load LLM model if enabled (background, non-blocking)
        let config = WhisprConfig.load()
        if config.llmEnabled && llmProcessor.isAvailable {
            Task {
                do {
                    try await llmProcessor.loadModel { progress in
                        NSLog("[Whispr] LLM download: \(Int(progress * 100))%")
                    }
                } catch {
                    NSLog("[Whispr] LLM load failed (non-fatal): \(error.localizedDescription)")
                }
            }
        }

        // Warm up audio engine so first recording starts instantly
        do {
            try audioRecorder.warmUp()
        } catch {
            NSLog("[Whispr] Audio warm-up failed (non-fatal): \(error.localizedDescription)")
        }

        // Set up hotkey
        setupHotkey()
        NSLog("[Whispr] Hotkey active. Hold Right Option to record.")
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.onRecordingStart = { [weak self] in
            Task { @MainActor in
                await self?.startRecording()
            }
        }

        hotkeyManager.onRecordingStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyManager.start()
    }

    // MARK: - Recording

    private func startRecording() async {
        guard appState.state == .ready else {
            NSLog("[Whispr] Cannot record — state is \(appState.state.statusText)")
            return
        }

        // Check microphone permission at point of use
        if !Permissions.checkMicrophone() {
            NSLog("[Whispr] Microphone permission not granted, requesting...")
            let granted = await Permissions.requestMicrophone()
            appState.hasMicrophonePermission = granted
            if !granted {
                NSLog("[Whispr] Microphone permission denied")
                appState.state = .error("Microphone access required")
                SoundEffects.playError()
                try? await Task.sleep(for: .seconds(2))
                appState.state = .ready
                return
            }
        }

        let config = WhisprConfig.load()
        if config.playSounds { SoundEffects.playStart() }

        // Try streaming mode first
        if config.useStreaming {
            do {
                try startStreamingRecording(config: config)
                return
            } catch {
                NSLog("[Whispr] Streaming init failed, falling back to batch: \(error)")
            }
        }

        // Batch mode fallback
        do {
            try audioRecorder.startRecording { level in
                Task { @MainActor [weak self] in
                    self?.appState.audioLevel = level
                }
            }
            appState.state = .recording
            menuBarIcon = "waveform.circle.fill"
            NSLog("[Whispr] Recording started (batch mode)")
        } catch {
            appState.state = .error(error.localizedDescription)
            NSLog("[Whispr] Recording failed: \(error)")
        }
    }

    private func startStreamingRecording(config: WhisprConfig) throws {
        // Start recording using our AudioRecorder (which works with AVCaptureDevice permission)
        try audioRecorder.startRecording { [weak self] level in
            Task { @MainActor [weak self] in
                self?.appState.audioLevel = level
                self?.overlay.updateAudioLevel(level)
            }
        }

        appState.state = .recording
        appState.isStreaming = true
        menuBarIcon = "waveform.circle.fill"

        // Show overlay near cursor
        overlay.show(near: NSEvent.mouseLocation)

        // Track last transcription to debounce (skip re-transcription if no new audio)
        var lastSampleCount = 0

        // Periodic transcription: every 1.0s, transcribe accumulated audio and update overlay
        streamingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(1000))
                if Task.isCancelled { break }

                let samples = self.audioRecorder.getAudioSamples()
                // Need at least 0.5s of audio
                guard samples.count > 8000 else { continue }

                // Debounce: skip if no significant new audio since last tick
                let newSamples = samples.count - lastSampleCount
                guard newSamples > 1600 else { continue } // at least 0.1s of new audio
                lastSampleCount = samples.count

                // Check audio energy before transcribing — skip if silence/noise
                let rms = samples.reduce(0.0) { $0 + $1 * $1 } / Float(samples.count)
                let rmsDb = 10 * log10(max(rms, 1e-10))
                if rmsDb < -45 {
                    NSLog("[Whispr] Streaming tick: audio too quiet (\(String(format: "%.1f", rmsDb)) dB), skipping")
                    continue
                }

                do {
                    let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
                    let result = try await self.transcriptionEngine.transcribe(
                        audioSamples: samples,
                        language: config.language,
                        promptText: promptHint
                    )
                    let text = Self.stripSpecialTokens(result.text)
                    if !text.isEmpty && !self.isHallucination(text) {
                        self.appState.streamingConfirmedText = text
                        self.appState.streamingUnconfirmedText = ""
                        self.overlay.update(confirmed: text, unconfirmed: "")
                    }
                } catch {
                    NSLog("[Whispr] Streaming transcription tick failed: \(error.localizedDescription)")
                }
            }
        }

        NSLog("[Whispr] Recording started (streaming mode)")
    }

    private func stopRecordingAndTranscribe() async {
        guard appState.state == .recording else { return }

        // Brief delay to capture the tail end of speech (user may still be finishing a word
        // when they lift their finger off the hotkey)
        try? await Task.sleep(for: .milliseconds(250))

        let config = WhisprConfig.load()
        menuBarIcon = "waveform"

        // Detect context before processing
        let context = ContextDetector.detectContext()
        NSLog("[Whispr] Detected context: \(context.rawValue)")

        if appState.isStreaming {
            await stopStreamingAndInsert(config: config, context: context)
        } else {
            await stopBatchAndInsert(config: config, context: context)
        }
    }

    // MARK: - Streaming Stop

    private func stopStreamingAndInsert(config: WhisprConfig, context: AppContext) async {
        // Capture last streaming result before cancelling (used as fallback)
        let lastStreamingText = appState.streamingConfirmedText

        // Stop periodic transcription
        streamingTask?.cancel()
        streamingTask = nil
        overlay.hide()

        // Stop recording and get ALL audio for final accurate transcription
        let allSamples = audioRecorder.stopRecording()
        appState.isStreaming = false

        guard allSamples.count > 8000 else {
            NSLog("[Whispr] Streaming: too short (\(allSamples.count) samples)")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Trim trailing silence for cleaner final transcription
        let samples = Self.trimTrailingSilence(allSamples, threshold: 0.005, minTrailingSamples: 8000)
        NSLog("[Whispr] Trimmed audio: \(allSamples.count) → \(samples.count) samples")

        // Do one final full transcription on trimmed audio (most accurate)
        appState.state = .transcribing
        do {
            let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
            let result = try await transcriptionEngine.transcribe(
                audioSamples: samples,
                language: config.language,
                promptText: promptHint
            )
            let rawText = Self.stripSpecialTokens(result.text)

            if !rawText.isEmpty, !isHallucination(rawText) {
                NSLog("[Whispr] Final transcription (\(String(format: "%.1f", result.duration))s): \(rawText)")
                await processAndInsert(rawText: rawText, config: config, context: context)
                return
            }

            // Final transcription was empty — fall back to last streaming result
            if !lastStreamingText.isEmpty, !isHallucination(lastStreamingText) {
                NSLog("[Whispr] Final transcription empty, using last streaming result: '\(lastStreamingText)'")
                await processAndInsert(rawText: lastStreamingText, config: config, context: context)
                return
            }

            NSLog("[Whispr] Filtered hallucination or empty: '\(rawText)'")
            appState.state = .ready
        } catch {
            // On error, try streaming fallback
            if !lastStreamingText.isEmpty, !isHallucination(lastStreamingText) {
                NSLog("[Whispr] Final transcription error, using last streaming result: '\(lastStreamingText)'")
                await processAndInsert(rawText: lastStreamingText, config: config, context: context)
                return
            }
            NSLog("[Whispr] Final transcription error: \(error)")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
        }
    }

    // MARK: - Batch Stop

    private func stopBatchAndInsert(config: WhisprConfig, context: AppContext) async {
        let samples = audioRecorder.stopRecording()

        // Need at least 0.5s of audio (8000 samples at 16kHz)
        guard samples.count > 8000 else {
            NSLog("[Whispr] Too short (\(samples.count) samples), ignoring")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Check audio energy
        let rms = samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)
        let rmsDb = 10 * log10(max(rms, 1e-10))
        NSLog("[Whispr] Audio RMS: \(String(format: "%.1f", rmsDb)) dB (\(samples.count) samples)")

        if rmsDb < -50 {
            NSLog("[Whispr] Audio too quiet (silence), ignoring")
            appState.state = .ready
            return
        }

        appState.state = .transcribing
        NSLog("[Whispr] Transcribing \(samples.count) samples...")

        do {
            let promptHint = CustomDictionary.promptHint(from: config.dictionaryEntries)
            let result = try await transcriptionEngine.transcribe(
                audioSamples: samples,
                language: config.language,
                promptText: promptHint
            )

            let trimmed = Self.stripSpecialTokens(result.text)
            guard !trimmed.isEmpty, !isHallucination(trimmed) else {
                NSLog("[Whispr] Filtered hallucination or empty: '\(trimmed)'")
                appState.state = .ready
                return
            }

            NSLog("[Whispr] Batch result (\(String(format: "%.1f", result.duration))s): \(trimmed)")
            await processAndInsert(rawText: trimmed, config: config, context: context)

        } catch {
            NSLog("[Whispr] Transcription error: \(error)")
            if config.playSounds { SoundEffects.playError() }
            // Error recovery: return to .ready immediately instead of hanging
            appState.state = .ready
        }
    }

    // MARK: - Process & Insert

    private func processAndInsert(rawText: String, config: WhisprConfig, context: AppContext) async {
        // Check for voice commands
        if config.llmEnabled, llmProcessor.isReady, let parsed = VoiceCommandParser.parse(rawText) {
            NSLog("[Whispr] Voice command detected: \(parsed.command)")
            await handleVoiceCommand(parsed.command, config: config)
            return
        }

        // Apply custom dictionary replacements
        var text = CustomDictionary.apply(entries: config.dictionaryEntries, to: rawText)

        // Post-process text with context
        let processor = TextPostProcessor(
            autoCapitalize: config.autoCapitalize,
            convertPunctuation: config.convertPunctuation,
            removeFiller: config.removeFiller
        )
        var processed = processor.process(text, context: context)

        // Optional LLM cleanup
        if config.llmEnabled && llmProcessor.isReady {
            appState.state = .transcribing
            // Pass dictionary terms to LLM for context
            llmProcessor.dictionaryTerms = config.dictionaryEntries
            processed = await llmProcessor.process(text: processed, context: context)
        }

        NSLog("[Whispr] Final text: \(processed)")

        // Save to history
        if config.historyEnabled {
            TranscriptionHistory.shared.add(rawText: rawText, processedText: processed, appContext: context)
        }

        // Check accessibility before inserting — request only at point of use
        if !Permissions.checkAccessibility() {
            appState.hasAccessibilityPermission = false
            NSLog("[Whispr] Accessibility not granted — copying to clipboard only")
            // Graceful degradation: copy to clipboard, user can paste manually
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(processed, forType: .string)
            appState.lastTranscription = processed
            if config.playSounds { SoundEffects.playStop() }
            appState.state = .ready

            // Prompt for accessibility once (not every time)
            if !UserDefaults.standard.bool(forKey: "whispr_accessibility_prompted") {
                UserDefaults.standard.set(true, forKey: "whispr_accessibility_prompted")
                _ = Permissions.requestAccessibility()
            }
            return
        }

        appState.hasAccessibilityPermission = true

        // Insert text via paste
        appState.state = .inserting
        await textInserter.insert(processed)

        appState.lastTranscription = processed
        if config.playSounds { SoundEffects.playStop() }
        appState.state = .ready
    }

    // MARK: - Voice Commands

    private func handleVoiceCommand(_ command: VoiceCommand, config: WhisprConfig) async {
        NSLog("[Whispr] Executing voice command...")

        // Capture selected text from the active app
        guard let selectedText = await VoiceCommandParser.captureSelectedText(), !selectedText.isEmpty else {
            NSLog("[Whispr] No text selected for voice command")
            if config.playSounds { SoundEffects.playError() }
            appState.state = .ready
            return
        }

        // Process with LLM
        let result = await llmProcessor.executeCommand(command, on: selectedText)

        // Replace selection with result
        appState.state = .inserting
        await textInserter.insert(result)

        appState.lastTranscription = result
        if config.playSounds { SoundEffects.playStop() }
        appState.state = .ready
    }

    // MARK: - Hallucination Filter

    private func isHallucination(_ text: String) -> Bool {
        let hallucinations: Set<String> = [
            "[BLANK_AUDIO]", "[BLANK AUDIO]", "(blank audio)",
            "[MUSIC]", "[SILENCE]", "[NOISE]",
            "you", "Thank you.", "Thanks for watching!",
            "Bye.", "Goodbye.", "...",
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return hallucinations.contains(trimmed)
    }

    /// Strip WhisperKit special tokens like <|startoftranscript|>, <|0.00|>, <|endoftext|>, etc.
    private static func stripSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trim trailing silence from audio samples to improve transcription accuracy.
    /// WhisperKit struggles when short speech is followed by long silence.
    /// - Parameters:
    ///   - samples: Raw PCM audio samples
    ///   - threshold: RMS amplitude below which audio is considered silence
    ///   - minTrailingSamples: Minimum trailing silent samples before trimming (0.5s = 8000 at 16kHz)
    private static func trimTrailingSilence(_ samples: [Float], threshold: Float = 0.005, minTrailingSamples: Int = 8000) -> [Float] {
        guard samples.count > minTrailingSamples else { return samples }

        // Scan backwards to find where audio rises above silence threshold
        // Use a sliding window of 1600 samples (0.1s) for smoothing
        let windowSize = 1600
        var lastLoudIndex = samples.count

        var i = samples.count - windowSize
        while i >= 0 {
            let window = samples[i..<min(i + windowSize, samples.count)]
            let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / Float(window.count))
            if rms > threshold {
                lastLoudIndex = min(i + windowSize + minTrailingSamples / 2, samples.count) // keep 0.25s padding after last sound
                break
            }
            i -= windowSize
        }

        // Don't trim if silence portion is too small to matter
        let trimmedCount = samples.count - lastLoudIndex
        if trimmedCount < minTrailingSamples {
            return samples
        }

        return Array(samples.prefix(lastLoudIndex))
    }
}
