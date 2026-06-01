import SwiftUI
import AppKit
import DynamicNotchKit

/// The Murmur Pro "Dynamic Island" — now backed by DynamicNotchKit, which provides the
/// native notch-hugging chrome and expand/collapse animation. We supply the content,
/// driven reactively by `IslandModel`. Dictation stays cursor-anchored
/// (TranscriptionOverlay); this is the Pro/AI layer's home.

@Observable
final class IslandModel {
    enum Phase: Equatable {
        case hidden
        case listening
        case thinking
        case confirm(summary: String)                                   // risky action — ask first
        case answer(String)                                             // spoken answer
        case done(String)                                               // "did X ✓"
        case result(instruction: String, before: String, after: String) // voice-edit before→after
        case message(String)
    }
    var phase: Phase = .hidden
    var level: Float = 0
}

@MainActor
final class IslandController {
    let model = IslandModel()
    var onUndo: (() -> Void)?
    var onRun: (() -> Void)?
    var onCancel: (() -> Void)?

    private var dismissTask: Task<Void, Never>?

    private lazy var notch: DynamicNotch<IslandView, EmptyView, EmptyView> = {
        let model = self.model
        return DynamicNotch(hoverBehavior: [.keepVisible], style: .auto) { [weak self] in
            IslandView(
                model: model,
                onUndo: { self?.onUndo?(); self?.dismiss() },
                onRun: { self?.onRun?() },
                onCancel: { self?.onCancel?(); self?.dismiss() }
            )
        }
    }()

    func listening() { present(.listening) }
    func thinking() { present(.thinking) }
    func confirm(summary: String) { present(.confirm(summary: summary)) }              // no auto-dismiss
    func answer(_ text: String) { present(.answer(text), autoDismiss: 9) }
    func done(_ text: String) { present(.done(text), autoDismiss: 4) }
    func message(_ text: String) { present(.message(text), autoDismiss: 4) }
    func showResult(instruction: String, before: String, after: String) {
        present(.result(instruction: instruction, before: before, after: after), autoDismiss: 7)
    }

    func updateLevel(_ level: Float) { model.level = level }

    func dismiss() {
        dismissTask?.cancel()
        Task { @MainActor in
            await notch.hide()
            model.phase = .hidden
        }
    }

    private func present(_ phase: IslandModel.Phase, autoDismiss seconds: Double? = nil) {
        dismissTask?.cancel()
        model.phase = phase
        Task { @MainActor in await notch.expand() }
        if let seconds { scheduleDismiss(after: seconds) }
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { self?.dismiss() }
        }
    }
}

// MARK: - View

private let signal = Color(red: 1.0, green: 0.48, blue: 0.16)

struct IslandView: View {
    let model: IslandModel
    let onUndo: () -> Void
    let onRun: () -> Void
    let onCancel: () -> Void

    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(maxWidth: 480, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
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
        case let .confirm(summary):
            confirmView(summary: summary)
        case let .answer(text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(signal).font(.system(size: 12)).padding(.top, 2)
                ScrollView {
                    Text(text)
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            .font(.system(size: 14, weight: .medium))
        case let .done(text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(signal)
                Text(text).foregroundStyle(.white.opacity(0.95)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14, weight: .medium))
        case let .result(instruction, before, after):
            resultView(instruction: instruction, before: before, after: after)
        case let .message(text):
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(signal).frame(width: 6, height: 6).padding(.top, 6)
                Text(text).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 14, weight: .medium))
        }
    }

    private func confirmView(summary: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("ABOUT TO")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(signal.opacity(0.9))
                Text(summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }.buttonStyle(.plain)
            Button(action: onRun) {
                Text("Run")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color(red: 0.1, green: 0.06, blue: 0.02))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(signal))
            }.buttonStyle(.plain)
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
                }.buttonStyle(.plain)
            }
            Text(before)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .strikethrough(color: .white.opacity(0.25))
                .lineLimit(3)
            Text(after)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
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
