import AppKit
import AVFoundation
import KVMKit
import SwiftUI

/// The USB Devices window: Openterface units plugged into this Mac, and
/// every camera, serial port and audio input the app can see, so a unit that
/// isn't recognised can be told apart from one that isn't connected.
struct USBDevicesView: View {
    static let windowID = "usb-devices"

    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var report = OpenterfaceScanner.Report()
    @State private var scanned: Date?

    var body: some View {
        VStack(spacing: 0) {
            List {
                unitsSection
                accessSection
                Section("Cameras") {
                    if report.cameras.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(report.cameras, id: \.uniqueID) { camera in
                        DetailRow(title: camera.name, recognised: camera.isOpenterface,
                                  lines: ["ID \(camera.uniqueID)", camera.modelID])
                    }
                }
                Section("Serial Ports") {
                    if report.serialPorts.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(report.serialPorts, id: \.path) { port in
                        DetailRow(title: port.path, recognised: port.chip != nil,
                                  lines: [Self.usbLine(vendor: port.vendor, product: port.product, location: port.location)
                                          + (port.chip.map { " · \($0)" } ?? "")])
                    }
                }
                Section("Audio Inputs") {
                    if report.audioInputs.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(report.audioInputs, id: \.uniqueID) { input in
                        DetailRow(title: input.name,
                                  recognised: report.units.contains { $0.audioID == input.uniqueID },
                                  lines: ["ID \(input.uniqueID)"])
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            HStack {
                if let scanned {
                    Text("Checked \(scanned.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy Details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(textReport, forType: .string)
                }
                .help("Copy everything listed here as text, for a bug report")
                Button("Refresh") { refresh() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { refresh() }
        // Plugging in or unplugging a camera re-scans. Serial ports appear
        // alongside it; give them a moment.
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            refreshSoon()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            refreshSoon()
        }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refresh() }
    }

    /// The device editor opens as a sheet on the main window, so bring it
    /// forward (or open it if it was closed).
    private func showMainWindow() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }

    /// The name in the sidebar of the device this unit is, once it's in the list.
    private func savedName(of unit: OpenterfaceUnit) -> String? {
        app.pluggedUnits.first { $0.value.id == unit.id }.flatMap { app.device($0.key)?.name }
    }

    private func refresh() {
        app.refreshUSB()
        report = OpenterfaceScanner.report()
        scanned = Date()
    }

    // MARK: Sections

    @ViewBuilder private var unitsSection: some View {
        Section {
            if report.units.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No Openterface found")
                    Text(report.cameras.isEmpty
                         ? "No USB camera is connected. Check that the Openterface's host cable (not its target cable) goes to this Mac."
                         : "None of the cameras below has an Openterface capture chip (MacroSilicon 534D:2109, 345F:2109 or 345F:2132).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            ForEach(report.units) { unit in
                UnitRow(unit: unit, savedName: savedName(of: unit)) {
                    app.editorRequest = .discovered(Device(name: "Openterface", model: .openterface,
                                                           endpoints: [], username: "", localDeviceID: unit.id))
                    showMainWindow()
                }
            }
        } header: {
            Text("Openterface")
        } footer: {
            Text("Units are added to the sidebar when they're plugged in, unless that's turned off in Settings. Rename one from its menu in the sidebar. Its keyboard and mouse need the serial port; its sound needs the audio input.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessSection: some View {
        if report.cameraAccess != .authorized || report.microphoneAccess != .authorized {
            Section("Permissions") {
                AccessRow(name: "Camera", purpose: "the Openterface's video", status: report.cameraAccess, mediaType: .video) { refresh() }
                AccessRow(name: "Microphone", purpose: "the Openterface's sound", status: report.microphoneAccess, mediaType: .audio) { refresh() }
            }
        }
    }

    // MARK: Text

    static func usbLine(vendor: Int?, product: Int?, location: UInt32?) -> String {
        guard let vendor, let product else { return "Not a USB device" }
        var line = String(format: "USB %04X:%04X", vendor, product)
        if let location { line += String(format: " at 0x%08X", location) }
        return line
    }

    private var textReport: String {
        var lines = ["KVM Console USB devices, \(Date().formatted())", ""]
        lines.append("Camera access: \(Self.describe(report.cameraAccess)); microphone access: \(Self.describe(report.microphoneAccess))")
        lines.append("")
        lines.append("Openterface units:")
        if report.units.isEmpty { lines.append("  none") }
        for unit in report.units {
            lines.append("  \(unit.displayName): video \(unit.id) (\(unit.videoName)), serial \(unit.serialPath ?? "none"), audio \(unit.audioName ?? "none"), USB serial number \(unit.serialNumber ?? "none"), listed as \(savedName(of: unit) ?? "not added")")
        }
        lines.append("Cameras:")
        for c in report.cameras { lines.append("  \(c.name) | \(c.uniqueID) | \(c.modelID)\(c.isOpenterface ? " | Openterface" : "")") }
        lines.append("Serial ports:")
        for p in report.serialPorts {
            lines.append("  \(p.path) | \(Self.usbLine(vendor: p.vendor, product: p.product, location: p.location))\(p.chip.map { " | \($0)" } ?? "")")
        }
        lines.append("Audio inputs:")
        for a in report.audioInputs { lines.append("  \(a.name) | \(a.uniqueID)") }
        return lines.joined(separator: "\n")
    }

    static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not asked yet"
        @unknown default: return "unknown"
        }
    }
}

private struct UnitRow: View {
    let unit: OpenterfaceUnit
    /// Its name in the sidebar, once added.
    let savedName: String?
    let add: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "cable.connector")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(savedName ?? unit.displayName).fontWeight(.medium)
                if savedName != nil {
                    Text(unit.displayName).font(.caption).foregroundStyle(.secondary)
                }
                part("Video", unit.videoName, ok: true)
                part("Keyboard and mouse", unit.serialPath ?? "serial port not found", ok: unit.serialPath != nil)
                part("Audio", unit.audioName ?? "not found", ok: unit.audioID != nil)
                if let serial = unit.serialNumber {
                    Text("USB serial number \(serial)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if savedName != nil {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add…", action: add)
            }
        }
        .padding(.vertical, 2)
    }

    private func part(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text("\(label): \(value)")
        }
        .font(.caption)
    }
}

private struct DetailRow: View {
    let title: String
    let recognised: Bool
    let lines: [String]

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
                    Text(line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            if recognised {
                Text("Openterface")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
        }
    }
}

private struct AccessRow: View {
    let name: String
    let purpose: String
    let status: AVAuthorizationStatus
    let mediaType: AVMediaType
    let changed: () -> Void

    var body: some View {
        HStack {
            Text("\(name): \(USBDevicesView.describe(status))")
            Text("needed for \(purpose)").foregroundStyle(.secondary)
            Spacer()
            switch status {
            case .notDetermined:
                Button("Allow…") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: mediaType)
                        changed()
                    }
                }
            case .denied, .restricted:
                Button("Open System Settings") {
                    let pane = mediaType == .video ? "Privacy_Camera" : "Privacy_Microphone"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            default:
                EmptyView()
            }
        }
    }
}
