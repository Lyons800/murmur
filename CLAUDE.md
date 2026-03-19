# Whispr — Project Conventions

## What is this?
Open-source macOS menu bar dictation app. Hold a hotkey, speak, release — text appears in any app. Powered by WhisperKit (on-device, CoreML + Neural Engine).

## Stack
- Swift 5.10+, macOS 14.0+ (Sonoma)
- SwiftUI (settings, onboarding) + AppKit (menu bar, status item)
- WhisperKit 0.9+ (speech-to-text via CoreML)
- AVAudioEngine (audio capture)
- CGEvent + NSPasteboard (text insertion)
- NSEvent globalMonitor (global hotkeys)

## Architecture
- Menu bar app (LSUIElement = true, no dock icon)
- Observable AppState drives all UI updates
- Core modules: AudioRecorder, TranscriptionEngine, HotkeyManager, TextInserter, TextPostProcessor, ContextDetector, LLMProcessor, VoiceCommandParser
- UI: StatusBarController (menu bar), TranscriptionOverlay (floating preview), SettingsView (SwiftUI)
- Two transcription modes: **streaming** (real-time via AudioStreamTranscriber with floating overlay) and **batch** (fallback, original mode)
- Context-aware formatting: ContextDetector reads frontmost app bundle ID → AppContext enum → TextPostProcessor adjusts capitalization/punctuation per context
- Optional LLM post-processing: LLMProcessor wraps mlx-swift-lm (MLXLLM) for local inference, guarded by `#if canImport(MLXLLM)`
- Voice commands: VoiceCommandParser detects trigger phrases ("fix grammar", "make professional", etc.) and routes to LLMProcessor

## Conventions
- Use async/await everywhere (no completion handlers)
- @Observable macro for state (not ObservableObject)
- Errors: throw, don't return optionals for failable operations
- Prefer value types (structs/enums) over classes except where reference semantics needed
- All audio processing on background queues, UI updates on @MainActor
- SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor — all types default to @MainActor unless explicitly opted out
- No third-party dependencies except WhisperKit (and optionally mlx-swift-lm for LLM) — keep it lean

## File Layout
- `Whispr/Core/` — business logic (audio, transcription, hotkeys, text insertion)
- `Whispr/UI/` — SwiftUI views and AppKit controllers
- `Whispr/Models/` — state, config, result types
- `Whispr/Utilities/` — permissions, key codes, sounds

## Key Decisions
- WhisperKit (CoreML) over whisper.cpp — 2-5x faster, 75% less power
- Clipboard paste over accessibility text insertion — works in 99% of apps
- Default model: base.en (142MB, ~500ms for 5s audio)
- Default hotkey: Right Option key
- Streaming mode on by default; batch mode as automatic fallback
- LLM post-processing off by default (requires adding mlx-swift-lm SPM package)
- Context detection via bundle ID map + fuzzy matching — no accessibility API needed

## Enabling LLM Post-Processing
1. In Xcode: File → Add Package Dependencies → `https://github.com/ml-explore/mlx-swift-lm.git`
2. Add the `MLXLLM` and `MLXLMCommon` products to the WhisprMacOS target
3. Build — the `#if canImport(MLXLLM)` guards will activate the LLM code
4. Enable in Settings → LLM tab → toggle "Enable LLM post-processing"
