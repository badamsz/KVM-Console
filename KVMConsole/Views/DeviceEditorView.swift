import PiKVMKit
import SwiftUI

struct DeviceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: EditorRequest

    @State private var device = Device(name: "")
    @State private var lanHost = ""
    @State private var tailscaleHost = ""
    @State private var password = ""
    @State private var hasSavedPassword = false
    @State private var testResult: String?
    @State private var testing = false

    private var isNew: Bool { if case .edit = request { return false } else { return true } }
    private var isSipeed: Bool { device.family.isSipeed }
    private var isLocal: Bool { device.family.isLocal }
    /// Openterface units plugged into this Mac, for the picker.
    @State private var units: [OpenterfaceUnit] = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Device") {
                    TextField("Name", text: $device.name, prompt: Text("Rack KVM"))
                    Picker("Model", selection: $device.model) {
                        Section("PiKVM") {
                            ForEach(PiKVMModel.allCases.filter { $0.family == .pikvm }) { Text($0.displayName).tag($0) }
                        }
                        Section("Sipeed") {
                            ForEach(PiKVMModel.allCases.filter { $0.family.isSipeed }) { Text($0.displayName).tag($0) }
                        }
                        Section("Plugged into this Mac") {
                            ForEach(PiKVMModel.allCases.filter { $0.family.isLocal }) { Text($0.displayName).tag($0) }
                        }
                    }
                }
                if isLocal {
                    localSection
                } else {
                    networkSections
                    certificateSection
                }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                HelpButton(topic: isLocal ? "openterface" : "adding-devices")
                Button("Test Connection") { Task { await test() } }
                    .disabled(testing || (!isLocal && assembled().endpoints.isEmpty))
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    model.save(assembled(), password: isLocal ? nil : password)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .frame(width: 460)
        .onAppear(perform: load)
        .task(id: isLocal) { if isLocal { units = OpenterfaceScanner.scan() } }
    }

    @ViewBuilder private var localSection: some View {
        Section {
            Picker("Unit", selection: $device.localDeviceID) {
                Text(units.isEmpty ? "None plugged in" : "The one plugged in").tag(String?.none)
                ForEach(units) { unit in
                    Text("\(unit.displayName) · \(unit.videoName)").tag(Optional(unit.id))
                }
                // Keep a saved unit selectable while it's unplugged.
                if let id = device.localDeviceID, !units.contains(where: { $0.id == id }) {
                    Text("Saved unit (not plugged in)").tag(Optional(id))
                }
            }
            Button("Look Again") { units = OpenterfaceScanner.scan() }
        } header: {
            Text("USB")
        } footer: {
            Text("Connect the Openterface's host cable to this Mac and its target cable and HDMI to the machine you want to control. Video and audio come in as a camera and microphone, so macOS asks for access the first time.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var networkSections: some View {
        Section {
            TextField("LAN address", text: $lanHost, prompt: Text(isSipeed ? "192.168.1.60 or nanokvm.local" : "192.168.1.50 or pikvm.local"))
            TextField("Tailscale address", text: $tailscaleHost, prompt: Text(isSipeed ? "nanokvm.tailnet-name.ts.net" : "pikvm.tailnet-name.ts.net"))
        } header: {
            Text("Addresses")
        } footer: {
            Text(isSipeed
                 ? "The LAN address is tried first, then Tailscale. HTTPS is tried before plain HTTP, which a NanoKVM uses unless HTTPS is turned on in its settings."
                 : "The LAN address is tried first, then Tailscale.")
                .foregroundStyle(.secondary)
        }
        Section {
            TextField("Username", text: $device.username)
            SecureField("Password", text: $password,
                        prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Required"))
        } header: {
            Text("Login")
        } footer: {
            Text(isSipeed
                 ? "The NanoKVM web login. The default is admin / admin until you change it."
                 : "If two-factor authentication is on, add the current code to the end of the password.")
                .foregroundStyle(.secondary)
        }
    }

    /// What the app learned about the device's certificate, with a way to
    /// forget it after the certificate was replaced on purpose.
    @ViewBuilder private var certificateSection: some View {
        if !isNew, device.certificateTrust != nil || device.pinnedCertificateSHA256 != nil {
            Section {
                LabeledContent("Certificate", value: device.certificateTrust == .certificateAuthority
                               ? "Issued by a certificate authority this Mac trusts"
                               : "Self-signed, saved on first connection")
                Button("Forget Certificate") {
                    device.resetCertificateTrust()
                    testResult = "The certificate will be learned again on the next connection after you save."
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Forget the certificate if you replaced it on the device or moved it to your own certificate authority.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var canSave: Bool {
        guard !device.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isLocal { return true }
        return !assembled().endpoints.isEmpty
            && (hasSavedPassword || !password.isEmpty)
    }

    private func load() {
        switch request {
        case .new:
            return
        case .discovered(let found):
            device = found
        case .edit(let id):
            guard let existing = model.device(id) else { return }
            device = existing
            hasSavedPassword = model.credentials.password(for: id) != nil
        }
        lanHost = device.endpoints.first { $0.label == "LAN" }?.host ?? ""
        tailscaleHost = device.endpoints.first { $0.label == "Tailscale" }?.host ?? ""
    }

    private func assembled() -> Device {
        var d = device
        d.name = d.name.trimmingCharacters(in: .whitespaces)
        var endpoints: [Endpoint] = []
        let lan = lanHost.trimmingCharacters(in: .whitespaces)
        let ts = tailscaleHost.trimmingCharacters(in: .whitespaces)
        if !lan.isEmpty {
            endpoints.append(device.endpoints.first { $0.label == "LAN" }.map { Endpoint(id: $0.id, label: "LAN", host: lan) }
                ?? Endpoint(label: "LAN", host: lan))
        }
        if !ts.isEmpty {
            endpoints.append(device.endpoints.first { $0.label == "Tailscale" }.map { Endpoint(id: $0.id, label: "Tailscale", host: ts) }
                ?? Endpoint(label: "Tailscale", host: ts))
        }
        d.endpoints = d.family.isLocal ? [] : endpoints
        if !d.family.isLocal { d.localDeviceID = nil }
        // Setting the name above also renames a single machine (`Device.name`).
        return d
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let pw = password.isEmpty ? (model.credentials.password(for: device.id) ?? "") : password
        var probe = assembled()
        probe.resetCertificateTrust()
        if probe.family.isLocal {
            units = OpenterfaceScanner.scan()
            if let unit = OpenterfaceScanner.unit(for: probe) {
                var parts = ["Found \(unit.displayName)"]
                parts.append(unit.serialPath == nil ? "but not its keyboard and mouse controller" : "with keyboard and mouse")
                parts.append(unit.audioID == nil ? "and no audio" : "and audio")
                testResult = parts.joined(separator: " ") + "."
            } else {
                testResult = "No Openterface is plugged into this Mac."
            }
            return
        }
        do {
            if probe.family.isSipeed {
                let conn = try await NanoKVMConnectionResolver.connect(to: probe, password: pw)
                let info = try? await conn.client.info()
                let scheme = conn.client.baseURL.scheme == "http" ? " over plain HTTP" : ""
                testResult = "Connected via \(conn.endpoint.label)\(scheme)"
                    + (info?.application.map { ", NanoKVM \($0)" } ?? "") + "."
            } else {
                let conn = try await ConnectionResolver.connect(to: probe, password: pw)
                let info = try? await conn.client.info()
                testResult = "Connected via \(conn.endpoint.label)" + (info?.kvmdVersion.map { ", kvmd \($0)" } ?? "") + "."
            }
        } catch {
            testResult = error.localizedDescription
        }
    }
}
