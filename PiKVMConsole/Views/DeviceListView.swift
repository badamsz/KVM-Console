import PiKVMKit
import SwiftUI

struct DeviceListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.devices) { device in
                if device.hasSwitch {
                    Section {
                        ForEach(device.targets) { target in
                            TargetRow(device: device, target: target)
                                .tag(TargetSelection(deviceID: device.id, targetID: target.id))
                        }
                    } header: {
                        DeviceHeader(device: device)
                    }
                } else if let target = device.targets.first {
                    TargetRow(device: device, target: target, subtitle: device.model.displayName)
                        .tag(TargetSelection(deviceID: device.id, targetID: target.id))
                        .contextMenu { DeviceMenu(device: device) }
                }
            }
        }
        .overlay {
            if model.devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "server.rack")
                } actions: {
                    Button("Add Device…") { model.editorRequest = .new }
                }
            }
        }
        .toolbar {
            Button { model.editorRequest = .new } label: { Label("Add Device", systemImage: "plus") }
        }
    }
}

private struct DeviceHeader: View {
    let device: Device

    var body: some View {
        HStack {
            Text(device.name)
            Spacer()
            Text(device.model.displayName).foregroundStyle(.secondary)
        }
        .contextMenu { DeviceMenu(device: device) }
    }
}

private struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        Button("Edit…") { model.editorRequest = .edit(device.id) }
        Button("Reconnect") { Task { await model.session(for: device.id).connect() } }
        Divider()
        Button("Remove", role: .destructive) { model.delete(device.id) }
    }
}

private struct TargetRow: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let target: Target
    var subtitle: String?

    var body: some View {
        let session = model.session(for: device.id)
        let leds = session.leds(for: target)
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
            VStack(alignment: .leading) {
                Text(target.name)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let port = target.switchPort, session.switchState?.activePort == port {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).help("Active switch port")
            }
            if let leds {
                Circle().fill(leds.power ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8).help(leds.power ? "Powered on" : "Powered off")
            }
        }
        .task { await session.connectIfNeeded() }
    }
}
