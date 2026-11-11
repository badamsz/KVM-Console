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
    @State private var pendingPower: PowerConfirmation?
    @AppStorage(ConsolePreferences.hideToolbarInFullScreenKey) private var hideToolbarInFullScreen = true
    @State private var powerActionRunning = false

    /// Power actions that interrupt the machine and so ask first.
    private enum PowerConfirmation {
        case reset, forceOff
    }

    var body: some View {
        let session = app.session(for: model.selection.deviceID)
        ZStack {
            ConsoleVideoView(model: model, frame: model.frame, liveView: model.webRTCView, videoSize: model.videoSize,
                             mouseMode: model.mouseMode, captured: model.mouseCaptured)
                .confirmationDialog(
                    pendingPower == .reset ? "Reset \(model.target?.name ?? "this machine")?" : "Force off \(model.target?.name ?? "this machine")?",
                    isPresented: Binding(get: { pendingPower != nil }, set: { if !$0 { pendingPower = nil } }),
                    presenting: pendingPower
                ) { action in
                    switch action {
                    case .reset:
                        Button("Reset", role: .destructive) { runPower(session) { try await session.click(.reset, for: $0) } }
                    case .forceOff:
                        Button("Force Off", role: .destructive) { runPower(session) { try await session.power(.offHard, for: $0) } }
                    }
                } message: { action in
                    switch action {
                    case .reset: Text("This presses the reset button and may lose unsaved work.")
                    case .forceOff: Text("This holds the power button and may lose unsaved work.")
                    }
                }
            overlay
            pasteStatus
        }
        .confirmationDialog(
            "Type \(model.pendingPaste?.count ?? 0) characters on \(model.target?.name ?? "the remote machine")?",
            isPresented: Binding(get: { model.pendingPaste != nil }, set: { if !$0 { model.pendingPaste = nil } }),
            presenting: model.pendingPaste
        ) { text in
            Button("Type It") { model.typeText(text) }
            Button("Cancel", role: .cancel) { model.pendingPaste = nil }
        } message: { text in
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
            let seconds = Int(TextPaste.estimatedDuration(characters: text.count, delay: model.typingRate.delay).rounded(.up))
            Text("\(lines) line\(lines == 1 ? "" : "s"), about \(seconds) second\(seconds == 1 ? "" : "s") at \(model.typingRate.displayName) speed. Each line break is typed as Enter.")
        }
        // The video stays below the toolbar; only the black backdrop extends under it.
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(model.target?.name ?? "Console")
        .navigationSubtitle(subtitle)
        .sheet(isPresented: Binding(get: { model.showingMedia }, set: { model.showingMedia = $0 })) { VirtualMediaView(deviceID: model.selection.deviceID).environment(app) }
        // In full screen the video can have the whole display; View > Hide Toolbar in Full Screen turns this off.
        .toolbar(model.isFullScreen && hideToolbarInFullScreen ? .hidden : .automatic, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup {
                Picker("Mouse", selection: Binding(get: { model.mouseMode }, set: { model.setMouseMode($0) })) {
                    ForEach(MouseMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Mouse mode for this machine")

                // Only machines with ATX wired up (directly or through the Switch) get these.
                if let target = model.target, let leds = session.leds(for: target) {
                    HStack(spacing: 8) {
                        Image(systemName: "power")
                            .foregroundStyle(leds.power ? Color.green : Color.secondary.opacity(0.4))
                            .help(leds.power ? "Power is on" : "Power is off")
                            .accessibilityLabel(leds.power ? "Power on" : "Power off")
                        Image(systemName: "internaldrive")
                            .foregroundStyle(leds.hdd ? Color.orange : Color.secondary.opacity(0.4))
                            .help("Disk activity")
                            .accessibilityLabel(leds.hdd ? "Disk active" : "Disk idle")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 4)

                    Menu {
                        Button("Power On") { runPower(session) { try await session.power(.on, for: $0) } }
                            .disabled(leds.power)
                        Button("Shut Down") { runPower(session) { try await session.power(.off, for: $0) } }
                            .disabled(!leds.power)
                        Divider()
                        Button("Reset…") { pendingPower = .reset }
                        Button("Force Off…") { pendingPower = .forceOff }
                    } label: {
                        Label("Power", systemImage: "bolt")
                    }
                    .disabled(powerActionRunning || session.atxBusy(for: target))
                    .help("Power controls for this machine")
                }

                if model.canChooseVideoMode {
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
                }

                if let side = model.sdCardSide {
                    Menu {
                        Picker("MicroSD Card", selection: Binding(get: { side }, set: { model.local?.setSDCard($0) })) {
                            Text("Connected to \(model.target?.name ?? "the Machine")").tag(CH9329.SDCardSide.target)
                            Text("Connected to This Mac").tag(CH9329.SDCardSide.host)
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Text("Eject the card on the side that has it before switching.")
                    } label: {
                        Label("MicroSD Card", systemImage: "sdcard")
                    }
                    .help(side == .target ? "The microSD card is connected to the machine" : "The microSD card is connected to this Mac")
                }

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

                if model.micAvailable || model.cameraAvailable {
                    Menu {
                        if model.micAvailable {
                            Toggle("Send Microphone", isOn: Binding(
                                get: { model.sendMic },
                                set: { model.setPassthrough(mic: $0, camera: model.sendCamera) }))
                        }
                        if model.cameraAvailable {
                            Toggle("Send Camera", isOn: Binding(
                                get: { model.sendCamera },
                                set: { model.setPassthrough(mic: model.sendMic, camera: $0) }))
                            if model.sendCamera, !model.sendingCamera {
                                Text(model.cameraInUse ? "Starting the camera…" : "Starts when an app on the remote machine opens the PiKVM camera")
                            }
                        }
                        Divider()
                        Text("The remote machine sees these as a USB microphone and webcam.")
                    } label: {
                        Label("Microphone and Camera",
                              systemImage: (model.sendingMic || model.sendingCamera) ? "video.and.waveform.fill" : "video.and.waveform")
                    }
                    .help((model.sendingMic || model.sendingCamera) ? "Sending this Mac's microphone or camera" : "Send this Mac's microphone or camera to the remote machine")
                }

                if session.msd?.enabled == true {
                    let mediaConnected = session.msd?.drive?.connected == true
                    Button { model.showingMedia = true } label: {
                        Label("Virtual Media", systemImage: mediaConnected ? "opticaldisc.fill" : "opticaldisc")
                    }
                    .help(mediaConnected ? "Virtual drive: \(session.msd?.drive?.image?.name ?? "connected")" : "Mount an ISO or disk image")
                }

                Menu {
                    Button("Ctrl+Alt+Del") { model.sendCombo(["ControlLeft", "AltLeft", "Delete"]) }
                    Button("Alt+Tab") { model.sendCombo(["AltLeft", "Tab"]) }
                    Button("Alt+F4") { model.sendCombo(["AltLeft", "F4"]) }
                    Button("Windows Key") { model.sendCombo(["MetaLeft"]) }
                    Button("Ctrl+Alt+F1") { model.sendCombo(["ControlLeft", "AltLeft", "F1"]) }
                    Button("Print Screen") { model.sendCombo(["PrintScreen"]) }
                    Divider()
                    Button("Paste Clipboard as Typing (⌥⌘V)") { model.pasteClipboard() }
                        .disabled(model.pasteProgress != nil)
                    Picker("Typing Speed", selection: Binding(get: { model.typingRate }, set: { model.typingRate = $0 })) {
                        ForEach(TypingRate.allCases) { rate in
                            Text("\(rate.displayName) (\(rate.detail))").tag(rate)
                        }
                    }
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

    private func runPower(_ session: DeviceSession, _ action: @escaping (Target) async throws -> Void) {
        guard let target = model.target else { return }
        Task {
            powerActionRunning = true
            defer { powerActionRunning = false }
            do { try await action(target) } catch { app.lastError = error.localizedDescription }
        }
    }

    @ViewBuilder private var pasteStatus: some View {
        if let progress = model.pasteProgress {
            VStack {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.typed), total: Double(max(progress.total, 1)))
                        .frame(width: 140)
                    Text("Typing \(progress.typed) of \(progress.total)")
                        .monospacedDigit()
                    Button("Cancel") { model.cancelPaste() }
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 12)
                Spacer()
            }
        }
    }

    private var subtitle: String {
        switch model.state {
        case .live:
            let size = model.videoSize
            let mode = model.activeVideoMode == .h264 ? "H.264" : "\(model.frameCodec) · \(model.fps) fps"
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
