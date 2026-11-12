import KVMKit
import SwiftUI

struct DeviceListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferences.showUnpluggedUSBKey) private var showUnpluggedUSB = false
    @State private var renaming: Device?
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        let devices = model.visibleDevices(showUnplugged: showUnpluggedUSB)
        List(selection: $model.selection) {
            ForEach(devices) { device in
                if device.hasSwitch {
                    Section {
                        ForEach(device.targets) { target in
                            TargetRow(device: device, target: target)
                                .tag(TargetSelection(deviceID: device.id, targetID: target.id))
                        }
                    } header: {
                        DeviceHeader(device: device, rename: startRenaming)
                            .modifier(ReorderableDevice(device: device))
                    }
                } else if let target = device.targets.first {
                    TargetRow(device: device, target: target,
                              subtitle: device.family.isLocal && model.pluggedUnits[device.id] == nil
                                  ? "Not plugged in" : device.model.displayName)
                        .modifier(ReorderableDevice(device: device))
                        .tag(TargetSelection(deviceID: device.id, targetID: target.id))
                }
            }
        }
        // Double-clicking (or pressing Return on) a machine behind an inactive Switch
        // port makes that port active; otherwise it opens the console.
        .contextMenu(forSelectionType: TargetSelection.self) { items in
            if let item = items.first, let device = model.device(item.deviceID) {
                TargetMenu(device: device, targetID: item.targetID, rename: startRenaming)
            }
        } primaryAction: { items in
            if let item = items.first, !model.switchPort(to: item) { openWindow(value: item) }
        }
        .overlay {
            if devices.isEmpty {
                ContentUnavailableView {
                    Label("No Devices", systemImage: "server.rack")
                } actions: {
                    Button("Find Devices…") { model.showingDiscovery = true }
                    Button("Add Device…") { model.editorRequest = .new }
                }
            }
        }
        .toolbar {
            Button { model.showingDiscovery = true } label: {
                Label("Find Devices", systemImage: "antenna.radiowaves.left.and.right")
            }
            .help("Find PiKVMs and NanoKVMs on your network, and Openterface KVMs plugged into this Mac")
            Button { model.editorRequest = .new } label: { Label("Add Device", systemImage: "plus") }
        }
        .alert("Rename \(renaming?.name ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { model.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func startRenaming(_ device: Device) {
        newName = device.name
        renaming = device
    }
}

private struct DeviceHeader: View {
    let device: Device
    let rename: (Device) -> Void

    var body: some View {
        HStack {
            Text(device.name)
            Spacer()
            Text(device.model.displayName).foregroundStyle(.secondary)
        }
        .contextMenu { DeviceMenu(device: device, rename: rename) }
    }
}

private struct TargetMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let device: Device
    let targetID: UUID
    let rename: (Device) -> Void

    var body: some View {
        let selection = TargetSelection(deviceID: device.id, targetID: targetID)
        if let target = device.targets.first(where: { $0.id == targetID }) {
            Button("Open Console") { openWindow(value: selection) }
            if target.switchPort != nil {
                Button("Switch to This Port") { model.switchPort(to: selection) }
                    .disabled(model.session(for: device.id).isOnScreen(target))
            }
            Divider()
        }
        DeviceMenu(device: device, rename: rename)
    }
}

private struct DeviceMenu: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPreferences.showUnpluggedUSBKey) private var showUnpluggedUSB = false
    let device: Device
    let rename: (Device) -> Void

    var body: some View {
        let above = model.sidebarNeighbour(of: device.id, offset: -1, showUnplugged: showUnpluggedUSB)
        let below = model.sidebarNeighbour(of: device.id, offset: 1, showUnplugged: showUnpluggedUSB)
        Button("Rename…") { rename(device) }
        Button("Edit…") { model.editorRequest = .edit(device.id) }
        Button("Reconnect") { Task { await model.session(for: device.id).connect() } }
        if device.family.supportsConfigurationEditing {
            Button("Configure \(device.family.shortName)…") { model.configRequest = ConfigRequest(deviceID: device.id) }
        }
        if device.family.supportsOSUpdate {
            Button("Update \(device.family.shortName) OS…") { model.updateRequest = UpdateRequest(deviceID: device.id) }
        }
        Divider()
        Button("Move Up") { if let above { withAnimation { model.moveDevice(device.id, onto: above) } } }
            .disabled(above == nil)
        Button("Move Down") { if let below { withAnimation { model.moveDevice(device.id, onto: below) } } }
            .disabled(below == nil)
        Divider()
        Button("Remove", role: .destructive) { model.delete(device.id) }
    }
}

/// What a device carries when dragged to reorder the sidebar. A plain string
/// with a prefix, so text dragged in from elsewhere is ignored.
private enum DeviceDrag {
    static let prefix = "kvm-console-device:"

    static func payload(_ id: UUID) -> String { prefix + id.uuidString }

    static func deviceID(from payload: String) -> UUID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}

/// Lets a device's sidebar row (or its Switch section header) be dragged onto
/// another device to move it there.
private struct ReorderableDevice: ViewModifier {
    @Environment(AppModel.self) private var model
    let device: Device
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .draggable(DeviceDrag.payload(device.id)) {
                Label(device.name, systemImage: device.hasSwitch ? "server.rack" : "desktopcomputer")
                    .padding(6)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.lazy.compactMap(DeviceDrag.deviceID).first, id != device.id else { return false }
                withAnimation { model.moveDevice(id, onto: device.id) }
                return true
            } isTargeted: { isTargeted = $0 }
            .background {
                if isTargeted { RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.25)).padding(-2) }
            }
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
        // Behind chained Switches, say which Switch and port this is ("Switch 2, port 3").
        let ports = session.switchState?.ports ?? []
        let caption = subtitle ?? target.switchPort.flatMap { p in ports.first { $0.index == p }?.location(inChainOf: ports) }
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
            VStack(alignment: .leading) {
                Text(target.name)
                if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if session.switchingTo == target.id {
                ProgressView().controlSize(.small).help("Switching to this port…")
            } else if let port = target.switchPort, session.switchState?.activePort == port {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).help("Active switch port")
            }
            if let leds {
                StatusLight(on: leds.power, size: 8).help(leds.power ? "Powered on" : "Powered off")
            }
        }
        .help(session.isOnScreen(target) ? "Double-click to open the console" : "Double-click to switch to this port")
        .task { await session.connectIfNeeded() }
    }
}
