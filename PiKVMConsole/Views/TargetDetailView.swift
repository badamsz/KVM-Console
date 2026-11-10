import PiKVMKit
import SwiftUI

struct TargetDetailView: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let target: Target

    @State private var confirmHardOff = false
    @State private var busy = false

    var body: some View {
        let session = model.session(for: device.id)
        Form {
            Section("Connection") {
                LabeledContent("Status") { StatusText(status: session.status) }
                if let v = session.info?.kvmdVersion { LabeledContent("kvmd", value: v) }
                if let h = session.info?.hostname { LabeledContent("Hostname", value: h) }
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
                Text("The remote console arrives in the next step.").foregroundStyle(.secondary)
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
        }
        .confirmationDialog("Force off \(target.name)?", isPresented: $confirmHardOff) {
            Button("Force Off", role: .destructive) { run { try await session.power(.offHard, for: target) } }
        } message: {
            Text("This holds the power button and may lose unsaved work.")
        }
        .task {
            await session.connectIfNeeded()
            if isActive(session) { try? await session.applyMouseMode(target.mouseMode) }
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
