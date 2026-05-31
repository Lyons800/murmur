import SwiftUI
import AppKit

/// The Murmur Pro "Dynamic Island" — a top-center floating surface that hosts the AI
/// moments (voice-edit before→after + Undo, and later Command Mode results). Dictation
/// stays cursor-anchored (TranscriptionOverlay); this is the Pro layer's home.

@Observable
final class IslandModel {
    enum Phase: Equatable {
        case hidden
        case listening
        case thinking
        case result(instruction: String, before: String, after: String)
        case message(String)
    }
    var phase: Phase = .hidden
    var level: Float = 0
}

/// Borderless panel that can still become key so the Undo button is clickable.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class IslandController {
    private var panel: NSPanel?
    let model = IslandModel()
    var onUndo: (() -> Void)?
    private var dismissTask: Task<Void, Never>?

    func listening() { model.phase = .listening; present() }
    func thinking() { model.phase = .thinking; present() }

    func showResult(instruction: String, before: String, after: String) {
        model.phase = .result(instruction: instruction, before: before, after: after)
        present()
        scheduleDismiss(after: 7)
    }

    func message(_ text: String) {
        model.phase = .message(text)
        present()
        scheduleDismiss(after: 3.5)
    }

    func updateLevel(_ level: Float) { model.level = level }

    func dismiss() {
        dismissTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel?.orderOut(nil)
                self?.model.phase = .hidden
            }
        })
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.dismiss() }
        }
    }

    private func present() {
        dismissTask?.cancel()
        if panel == nil { createPanel() }
        guard let panel, let screen = NSScreen.main else { return }

        let width: CGFloat = 480
        let height: CGFloat = 150
        let vf = screen.visibleFrame
        let frame = NSRect(x: vf.midX - width / 2, y: vf.maxY - height + 30, width: width, height: height)
        panel.setFrame(frame, display: true)

        if panel.isVisible && panel.alphaValue > 0.9 {
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                panel.animator().alphaValue = 1
            }
        }
    }

    private func createPanel() {
        let panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let view = IslandView(model: model, onUndo: { [weak self] in
            self?.onUndo?()
            self?.dismiss()
        })
        panel.contentView = NSHostingView(rootView: view)
        self.panel = panel
    }
}

// MARK: - View

private let signal = Color(red: 1.0, green: 0.48, blue: 0.16)

struct IslandView: View {
    let model: IslandModel
    let onUndo: () -> Void

    var body: some View {
        VStack {
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: 460)
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.black.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(signal.opacity(0.22), lineWidth: 1))
                }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .hidden:
            EmptyView()
        case .listening:
            HStack(spacing: 12) {
                EqBars(level: model.level)
                Text("Listening for a command…").foregroundStyle(.white.opacity(0.85))
            }
            .font(.system(size: 14, weight: .medium))
        case .thinking:
            HStack(spacing: 12) {
                ProgressView().scaleEffect(0.6).tint(signal)
                Text("Working…").foregroundStyle(.white.opacity(0.85))
            }
            .font(.system(size: 14, weight: .medium))
        case let .result(instruction, before, after):
            resultView(instruction: instruction, before: before, after: after)
        case let .message(text):
            HStack(spacing: 10) {
                Circle().fill(signal).frame(width: 6, height: 6)
                Text(text).foregroundStyle(.white.opacity(0.9))
            }
            .font(.system(size: 14, weight: .medium))
        }
    }

    private func resultView(instruction: String, before: String, after: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").foregroundStyle(signal).font(.system(size: 11))
                Text(instruction.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(signal.opacity(0.9))
                    .lineLimit(1)
                Spacer()
                Button(action: onUndo) {
                    Text("Undo")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            Text(before)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .strikethrough(color: .white.opacity(0.25))
                .lineLimit(2)
            Text(after)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
        }
    }
}

private struct EqBars: View {
    let level: Float
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                let base = CGFloat(max(0.12, min(level * 6, 1)))
                let h = max(0.15, base * (0.5 + 0.5 * abs(sin(Double(i) * 1.3))))
                RoundedRectangle(cornerRadius: 2)
                    .fill(signal)
                    .frame(width: 3, height: 6 + h * 16)
                    .animation(.interpolatingSpring(stiffness: 280, damping: 12), value: level)
            }
        }
        .frame(height: 22)
    }
}
