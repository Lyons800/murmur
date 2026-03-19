import SwiftUI
import AppKit

@Observable
final class OverlayContentModel {
    var confirmedText: String = ""
    var unconfirmedText: String = ""
    var isVisible: Bool = false
    var audioLevel: Float = 0.0
}

final class TranscriptionOverlay {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayContentView>?
    let contentModel = OverlayContentModel()

    func show(near point: NSPoint) {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Position below the mouse cursor
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main!
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 60

        var x = point.x - panelWidth / 2
        var y = point.y - panelHeight - 24

        // Keep within screen bounds
        let screenFrame = screen.visibleFrame
        x = max(screenFrame.minX + 8, min(x, screenFrame.maxX - panelWidth - 8))
        y = max(screenFrame.minY + 8, min(y, screenFrame.maxY - panelHeight - 8))

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        contentModel.confirmedText = ""
        contentModel.unconfirmedText = ""
        contentModel.isVisible = true

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func updateAudioLevel(_ level: Float) {
        contentModel.audioLevel = level
    }

    func update(confirmed: String, unconfirmed: String) {
        contentModel.confirmedText = confirmed
        contentModel.unconfirmedText = unconfirmed

        // Auto-resize panel to fit content, anchoring at top-left
        if let panel, let hostingView {
            let fitting = hostingView.fittingSize
            let width = min(max(fitting.width + 32, 200), 500)
            let height = min(max(fitting.height + 16, 44), 200)
            var frame = panel.frame
            let topY = frame.maxY // anchor at top edge
            frame.size = NSSize(width: width, height: height)
            frame.origin.y = topY - height // keep top edge fixed
            panel.setFrame(frame, display: true, animate: false)
        }
    }

    func hide() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            self?.contentModel.isVisible = false
            self?.contentModel.confirmedText = ""
            self?.contentModel.unconfirmedText = ""
        })
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        let contentView = OverlayContentView(model: contentModel)
        let hosting = NSHostingView(rootView: contentView)
        panel.contentView = hosting

        self.panel = panel
        self.hostingView = hosting
    }
}

struct WaveformView: View {
    let audioLevel: Float
    let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                WaveformBar(audioLevel: audioLevel, index: index)
            }
        }
        .frame(height: 16)
    }
}

struct WaveformBar: View {
    let audioLevel: Float
    let index: Int

    // Each bar gets a slightly different response curve for organic feel
    private var barHeight: CGFloat {
        let base = CGFloat(min(max(audioLevel, 0), 1))
        let offset = sin(Double(index) * 1.3) * 0.15
        let height = base + CGFloat(offset) * base
        return max(0.15, min(height, 1.0))
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(.white.opacity(0.8))
            .frame(width: 3, height: 4 + barHeight * 12)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: barHeight)
    }
}

struct OverlayContentView: View {
    let model: OverlayContentModel

    var body: some View {
        HStack(spacing: 8) {
            if model.confirmedText.isEmpty && model.unconfirmedText.isEmpty {
                WaveformView(audioLevel: model.audioLevel)
                Text("Listening...")
                    .foregroundStyle(.secondary)
            } else {
                // Show small waveform indicator while recording with text
                WaveformView(audioLevel: model.audioLevel)
                    .scaleEffect(0.7)
                    .opacity(0.6)
                Text("\(Text(model.confirmedText).foregroundStyle(.white))\(Text(model.unconfirmedText).foregroundStyle(.white.opacity(0.5)))")
            }
        }
        .font(.system(size: 14, weight: .medium))
        .lineLimit(6)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 500, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
                }
        }
    }
}
