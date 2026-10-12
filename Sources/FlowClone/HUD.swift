import AppKit
import SwiftUI

/// Floating pill at the bottom of the screen showing what dictation is doing,
/// like Wispr Flow's recording overlay. Never takes focus, so pasting still
/// goes to the app the user was typing in.
@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable { case hidden, recording, processing, message(String) }

    @Published var phase = Phase.hidden
    /// Shift joined the push-to-talk hold: speech is an instruction, not dictation.
    @Published var commandMode = false
    @Published var levels = [Float](repeating: 0, count: 14)

    func push(level: Float) {
        levels.removeFirst()
        levels.append(level)
    }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .recording:
                if model.commandMode {
                    Image(systemName: "wand.and.stars").foregroundStyle(.white)
                    Text("Command").foregroundStyle(.white)
                } else {
                    Circle().fill(.red).frame(width: 8, height: 8)
                }
                HStack(spacing: 3) {
                    ForEach(model.levels.indices, id: \.self) { i in
                        Capsule()
                            .fill(.white)
                            .frame(width: 3, height: 4 + CGFloat(min(1, model.levels[i])) * 18)
                    }
                }
                .animation(.easeOut(duration: 0.08), value: model.levels)
            case .processing:
                ProgressView().controlSize(.small).tint(.white)
                Text(model.commandMode ? "Working on it…" : "Transcribing…").foregroundStyle(.white)
            case .message(let text):
                Text(text).foregroundStyle(.white)
            case .hidden:
                EmptyView()
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Capsule().fill(model.commandMode && model.phase != .hidden
            ? Color.purple.opacity(0.9) : Color.black.opacity(0.85)))
        .overlay(Capsule().stroke(.white.opacity(0.15)))
        .fixedSize()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 50),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ phase: HUDModel.Phase, autoHideAfter seconds: Double? = nil) {
        hideTask?.cancel()
        if phase == .recording { model.levels = model.levels.map { _ in 0 } }
        model.phase = phase
        guard phase != .hidden else { panel.orderOut(nil); return }
        position()
        panel.orderFrontRegardless()
        if let seconds {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { show(.hidden) }
            }
        }
    }

    /// Bottom-centre of the screen the mouse is on, above the Dock.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 24))
    }
}
