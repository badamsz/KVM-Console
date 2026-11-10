import PiKVMKit
import SwiftUI

/// The contents of a console window for one machine.
struct ConsoleWindow: View {
    @Environment(AppModel.self) private var app
    let selection: TargetSelection
    @State private var model: ConsoleModel?

    var body: some View {
        Group {
            if let model {
                ConsoleContent(model: model)
            } else {
                Color.black
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .onAppear {
            if model == nil {
                let m = ConsoleModel(selection: selection, app: app)
                model = m
                m.start()
            }
        }
        .onDisappear {
            model?.stop()
            model = nil
        }
    }
}

private struct ConsoleContent: View {
    @Environment(AppModel.self) private var app
    let model: ConsoleModel

    var body: some View {
        ZStack {
            ConsoleVideoView(model: model, frame: model.frame, liveView: model.webRTCView, videoSize: model.videoSize,
                             mouseMode: model.mouseMode, captured: model.mouseCaptured)
            overlay
        }
        // The video stays below the toolbar; only the black backdrop extends under it.
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(model.target?.name ?? "Console")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Picker("Mouse", selection: Binding(get: { model.mouseMode }, set: { model.setMouseMode($0) })) {
                    ForEach(MouseMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Mouse mode for this machine")

                Menu {
                    Picker("Video", selection: Binding(get: { model.videoMode }, set: { model.setVideoMode($0) })) {
                        ForEach(VideoMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                    if let reason = model.fallbackReason {
                        Text("Using MJPEG: \(reason)")
                    }
                } label: {
                    Label("Video", systemImage: "play.rectangle")
                }
                .help("Video mode")

                if model.audioAvailable {
                    Menu {
                        Toggle("Mute", isOn: Binding(get: { model.muted }, set: { model.muted = $0 }))
                        Divider()
                        ForEach([100, 75, 50, 25], id: \.self) { percent in
                            Button {
                                model.volume = Double(percent) / 100
                                model.muted = false
                            } label: {
                                if Int((model.volume * 100).rounded()) == percent, !model.muted {
                                    Label("\(percent)%", systemImage: "checkmark")
                                } else {
                                    Text("\(percent)%")
                                }
                            }
                        }
                    } label: {
                        Label("Audio", systemImage: model.muted ? "speaker.slash" : "speaker.wave.2")
                    }
                    .help("Remote audio")
                }

                Menu {
                    Button("Ctrl+Alt+Del") { model.sendCombo(["ControlLeft", "AltLeft", "Delete"]) }
                    Button("Alt+Tab") { model.sendCombo(["AltLeft", "Tab"]) }
                    Button("Alt+F4") { model.sendCombo(["AltLeft", "F4"]) }
                    Button("Windows Key") { model.sendCombo(["MetaLeft"]) }
                    Button("Ctrl+Alt+F1") { model.sendCombo(["ControlLeft", "AltLeft", "F1"]) }
                    Button("Print Screen") { model.sendCombo(["PrintScreen"]) }
                } label: {
                    Label("Send Keys", systemImage: "keyboard")
                }
                .help("Send a key combination macOS would otherwise keep")

                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .help("Full screen (Ctrl+Cmd+F)")
            }
        }
    }

    private var subtitle: String {
        switch model.state {
        case .live:
            let size = model.videoSize
            let mode = model.activeVideoMode == .h264 ? "H.264" : "MJPEG · \(model.fps) fps"
            return "\(Int(size.width))×\(Int(size.height)) · \(mode)"
                + (model.mouseCaptured ? " · Control+Option releases the mouse" : "")
        case .connecting: return "Connecting…"
        case .noSignal: return "No signal"
        case .failed: return "Disconnected"
        }
    }

    @ViewBuilder private var overlay: some View {
        switch model.state {
        case .live:
            if model.mouseMode == .relative, !model.mouseCaptured {
                hint("Click to capture the mouse. Press Control+Option to release it.")
            }
        case .connecting:
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Connecting…")
            }
            .foregroundStyle(.white)
        case .noSignal:
            VStack(spacing: 10) {
                Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                Text("No video signal")
                Text("The machine may be off or asleep. Keyboard and mouse still work.").font(.caption)
            }
            .foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center)
                Text("Retrying…").font(.caption)
            }
            .foregroundStyle(.white)
            .padding()
        }
    }

    private func hint(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.callout)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(.bottom, 16)
        }
        .allowsHitTesting(false)
    }
}
