import PiKVMKit
import SwiftUI

struct TargetDetailView: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let target: Target

    @Environment(\.openWindow) private var openWindow
    @State private var confirmHardOff = false
    @State private var busy = false
    @State private var showingMedia = false

    var body: some View {
        let session = model.session(for: device.id)
        Form {
            Section("Screen") {
                ScreenPreviewView(session: session, target: target) {
                    openWindow(value: TargetSelection(deviceID: device.id, targetID: target.id))
                }
            }

            Section("Connection") {
                LabeledContent("Status") { StatusText(status: session.status) }
                if let v = session.info?.kvmdVersion { LabeledContent("kvmd", value: v) }
                if let v = session.nanoInfo?.application, !v.isEmpty { LabeledContent("NanoKVM software", value: v) }
                if let h = session.nanoInfo?.mdns, !h.isEmpty { LabeledContent("Hostname", value: h) }
                if let h = session.info?.hostname { LabeledContent("Hostname", value: h) }
                switch device.certificateTrust {
                case .certificateAuthority:
                    LabeledContent("Certificate", value: "Issued by a certificate authority this Mac trusts")
                case .pinned:
                    LabeledContent("Certificate", value: "Self-signed, saved on first connection")
                case nil:
                    EmptyView()
                }
                if let port = target.switchPort {
                    LabeledContent("Switch port") {
                        HStack {
                            Text(session.switchState?.ports.first { $0.index == port }?.displayID ?? "\(port + 1)")
                            if session.switchState?.activePort == port {
                                Text("Active").foregroundStyle(.tint)
                            } else {
                                Button("Switch to This Port") { run { try await session.activate(target) } }
                            }
                        }
                    }
                }
                if let beacon = session.beacon(for: target) {
                    Toggle("Blink this port's light on the Switch", isOn: Binding(
                        get: { beacon },
                        set: { on in run { try await session.setBeacon(on, for: target) } }
                    ))
                    .help("Helps find this machine's port and cables on the Switch")
                }
            }

            Section("Console") {
                Picker("Mouse mode", selection: Binding(
                    get: { target.mouseMode },
                    set: { mode in
                        model.setMouseMode(mode, deviceID: device.id, targetID: target.id)
                        if isActive(session) { run { try await session.applyMouseMode(mode) } }
                    }
                )) {
                    ForEach(MouseMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                if let hid = session.hid, !hid.supportedMouseModes.contains(.relative) {
                    Text("Relative mode isn't enabled on this PiKVM. Turn on the alternate mouse in kvmd's OTG settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    openWindow(value: TargetSelection(deviceID: device.id, targetID: target.id))
                } label: {
                    Label("Open Console", systemImage: "display")
                }
                .controlSize(.large)
                .disabled(!session.isConnected)
            }

            if let msd = session.msd, msd.enabled {
                Section("Virtual Media") {
                    LabeledContent("Drive") {
                        if msd.drive?.connected == true, let image = msd.drive?.image {
                            Text("\((image.name as NSString).lastPathComponent) connected")
                        } else {
                            Text("Nothing connected").foregroundStyle(.secondary)
                        }
                    }
                    if let upload = session.upload {
                        ProgressView("Uploading \(upload.name)", value: Double(upload.sent), total: Double(max(upload.total, 1)))
                    }
                    Button { showingMedia = true } label: { Label("Manage Images…", systemImage: "opticaldisc") }
                }
            }

            Section("Power") {
                if let leds = session.leds(for: target) {
                    LabeledContent("Power LED") { LED(on: leds.power, color: .green) }
                    LabeledContent("HDD LED") { LED(on: leds.hdd, color: .orange) }
                    HStack {
                        Button("Power On") { run { try await session.power(.on, for: target) } }
                            .disabled(leds.power)
                        Button("Shut Down") { run { try await session.power(.off, for: target) } }
                            .disabled(!leds.power)
                        Button("Reset") { run { try await session.click(.reset, for: target) } }
                        Button("Force Off", role: .destructive) { confirmHardOff = true }
                    }
                    .disabled(busy)
                } else {
                    Text("ATX control isn't available for this machine.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(target.name)
        .navigationSubtitle(device.hasSwitch ? device.name : device.model.displayName)
        .toolbar {
            Button { Task { await session.connect() } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            Button { model.editorRequest = .edit(device.id) } label: { Label("Edit Device", systemImage: "slider.horizontal.3") }
            if device.family == .pikvm {
                Button { model.configRequest = ConfigRequest(deviceID: device.id) } label: {
                    Label("Configure PiKVM", systemImage: "gearshape")
                }
                .help("View and change this PiKVM's settings (override.yaml)")
                Button { model.updateRequest = UpdateRequest(deviceID: device.id) } label: {
                    Label("Update PiKVM OS", systemImage: "arrow.down.circle")
                }
                .help("Run pikvm-update on this PiKVM")
            }
        }
        .sheet(isPresented: $showingMedia) { VirtualMediaView(deviceID: device.id).environment(model) }
        .confirmationDialog("Force off \(target.name)?", isPresented: $confirmHardOff) {
            Button("Force Off", role: .destructive) { run { try await session.power(.offHard, for: target) } }
        } message: {
            Text("This holds the power button and may lose unsaved work.")
        }
        .task {
            await session.connectIfNeeded()
            if isActive(session) { try? await session.applyMouseMode(target.mouseMode) }
            if session.previews[target.id]?.image == nil { await session.refreshPreview(for: target) }
        }
    }

    private func isActive(_ session: DeviceSession) -> Bool {
        target.switchPort == nil || session.switchState?.activePort == target.switchPort
    }

    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await action() } catch { model.lastError = error.localizedDescription }
        }
    }
}

/// A still picture of the machine's screen with a refresh button.
private struct ScreenPreviewView: View {
    let session: DeviceSession
    let target: Target
    let openConsole: () -> Void

    var body: some View {
        let preview = session.previews[target.id]
        let loading = session.previewsLoading.contains(target.id)
        let onScreen = session.isOnScreen(target)
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                if let image = preview?.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .opacity(onScreen ? 1 : 0.4)
                } else if !loading {
                    Text(onScreen ? "No preview yet" : "Switch to this port to see its screen")
                        .foregroundStyle(.white.opacity(0.7))
                }
                if loading { ProgressView().controlSize(.large) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 230)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: openConsole)
            .help("Double-click to open the console")

            HStack {
                if let error = preview?.error {
                    Text(error).foregroundStyle(.red).lineLimit(2)
                } else if !onScreen, preview?.image != nil {
                    Text("Not the active Switch port. This picture is from \(preview?.date?.formatted(date: .omitted, time: .shortened) ?? "earlier").")
                        .foregroundStyle(.secondary)
                } else if let date = preview?.date {
                    Text("Updated \(date.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await session.refreshPreview(for: target) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(loading || !onScreen || !session.isConnected)
                .help(onScreen ? "Take a new picture of the screen" : "The PiKVM only sees the active Switch port")
            }
            .font(.callout)
        }
    }
}

private struct StatusText: View {
    let status: DeviceSession.Status

    var body: some View {
        switch status {
        case .idle: Text("Not connected").foregroundStyle(.secondary)
        case .connecting: HStack { ProgressView().controlSize(.small); Text("Connecting…") }
        case .connected(let label, let host): Text("Connected via \(label) (\(host))")
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
    }
}

private struct LED: View {
    let on: Bool
    let color: Color

    var body: some View {
        Circle().fill(on ? color : Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
    }
}
