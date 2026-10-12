import AppKit
import AVFoundation
import SwiftUI

/// Status shown in the setup window; refreshed by the controller and by a timer
/// (permission changes made in System Settings don't notify us).
@MainActor
final class SetupModel: ObservableObject {
    @Published var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var accessibility = AXIsProcessTrusted()
    @Published var modelStatus = "Preparing…"
    @Published var modelReady = false
    /// The local formatting model; optional for dictation, so not part of `allGood`.
    @Published var textModelStatus = ""
    @Published var textModelReady = false
    @Published var hotkeyLabel = ""
    @Published var hotkeyListening = false
    @Published var hotkeySeen = false

    var allGood: Bool { microphone == .authorized && accessibility && modelReady && hotkeyListening }

    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
    }
}

private struct SetupView: View {
    @ObservedObject var model: SetupModel
    let close: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "mic.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("FlowClone").font(.title2.bold())
                    Text("Lives in the menu bar — look for the \(Image(systemName: "mic")) icon at the top right.")
                        .foregroundStyle(.secondary)
                }
            }

            row(ok: model.microphone == .authorized, title: "Microphone",
                detail: model.microphone == .denied ? "Denied — enable FlowClone in Settings" : "Needed to hear you") {
                if model.microphone == .notDetermined {
                    Button("Allow") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); model.refresh() } }
                } else {
                    Button("Open Settings") { openSettings("Privacy_Microphone") }
                }
            }
            row(ok: model.accessibility, title: "Accessibility",
                detail: "Needed for the hotkey, reading the text field and pasting") {
                Button("Open Settings") {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    openSettings("Privacy_Accessibility")
                }
            }
            row(ok: model.modelReady, title: "Speech model", detail: model.modelStatus) { EmptyView() }
            if !model.textModelStatus.isEmpty {
                row(ok: model.textModelReady, title: "Text model",
                    detail: model.textModelReady ? model.textModelStatus
                        : "\(model.textModelStatus). Cleanup uses Apple's model meanwhile, if available.") { EmptyView() }
            }
            row(ok: model.hotkeyListening && model.hotkeySeen, title: "Hotkey test",
                detail: !model.hotkeyListening ? "Keyboard listener not running yet (needs Accessibility)"
                    : model.hotkeySeen ? "\(model.hotkeyLabel) detected" : "Press \(model.hotkeyLabel) once — this turns green") { EmptyView() }

            Divider()
            Text(model.allGood
                 ? "Ready. Click into any text field, hold \(model.hotkeyLabel), speak, release."
                 : "If FlowClone is already enabled in Accessibility but still shows ✗, remove it with “–”, add it again, then relaunch.")
                .font(.callout)
                .foregroundStyle(model.allGood ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(model.allGood ? "Done" : "Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onReceive(timer) { _ in model.refresh() }
    }

    private func row<Action: View>(ok: Bool, title: String, detail: String,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            VStack(alignment: .leading) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { action() }
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

@MainActor
final class SetupWindowController {
    private var window: NSWindow?

    func show(model: SetupModel) {
        if window == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.title = "FlowClone Setup"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SetupView(model: model) { [weak window] in window?.close() })
            window.center()
            self.window = window
        }
        model.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
