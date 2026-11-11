import PiKVMKit
import SwiftUI

/// Find Devices: lists KVMs found with Bonjour, a subnet scan or Tailscale,
/// each with an Add button that opens the device editor prefilled.
struct DiscoveryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var discovery: DiscoveryModel?
    @State private var editing: EditorRequest?

    var body: some View {
        VStack(spacing: 0) {
            if let discovery {
                DiscoveryContent(discovery: discovery, editing: $editing)
            } else {
                Spacer()
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 600, height: 560)
        .onAppear {
            let model = discovery ?? DiscoveryModel(credentials: app.credentials)
            discovery = model
            model.start()
        }
        .onDisappear { discovery?.stop() }
        .sheet(item: $editing) { request in
            DeviceEditorView(request: request)
        }
    }
}

private struct DiscoveryContent: View {
    @Environment(AppModel.self) private var app
    let discovery: DiscoveryModel
    @Binding var editing: EditorRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find Devices").font(.title2.bold())
                Text("PiKVMs and NanoKVMs on your network and tailnet. Nothing is sent to a device except a request for its login page.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 8)

            List {
                Section {
                    if discovery.results.devices.isEmpty {
                        EmptyResults(discovery: discovery)
                    }
                    ForEach(discovery.results.devices) { device in
                        FoundRow(device: device,
                                 added: DiscoveryResults.isAlreadyAdded(device, in: app.devices)) {
                            editing = .discovered(device.makeDevice())
                        }
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text("Found")
                        ProgressView().controlSize(.mini)
                            .help("Listening for Bonjour announcements")
                    }
                }

                Section {
                    ScanControls(discovery: discovery)
                } header: {
                    Text("Network Scan")
                } footer: {
                    Text("Checks every address on your local network for a KVM web server on ports 443 and 80.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    TailscaleControls(discovery: discovery)
                } header: {
                    Text("Tailscale")
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct EmptyResults: View {
    let discovery: DiscoveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(discovery.isScanning || discovery.isCheckingTailscale ? "Searching…" : "Nothing found yet")
            Text("PiKVMs announce themselves with Bonjour only when Avahi is turned on (add ENABLE_AVAHI=1 to /boot/pikvm.txt, or run systemctl enable --now avahi-daemon). Scan the network to find the rest.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

private struct FoundRow: View {
    let device: DiscoveredDevice
    let added: Bool
    let add: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.kind.isPiKVM ? "server.rack" : "cube")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).fontWeight(.medium)
                    Text(device.kind.displayName).foregroundStyle(.secondary)
                }
                Text(addressLine).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 4) {
                    ForEach(device.sources.sorted(), id: \.self) { source in
                        Text(source.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    if let platform = device.details["platform"] {
                        Text(platform).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if added {
                Label("Added", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add…", action: add)
            }
        }
        .padding(.vertical, 2)
    }

    private var addressLine: String {
        var parts: [String] = []
        if let lan = device.lanHost { parts.append("LAN \(lan)") }
        if let ts = device.tailscaleHost { parts.append("Tailscale \(ts)") }
        return parts.joined(separator: "  ·  ")
    }
}

private struct ScanControls: View {
    let discovery: DiscoveryModel

    var body: some View {
        if discovery.subnets.isEmpty {
            Text("This Mac isn't on a local IPv4 network.").foregroundStyle(.secondary)
        } else if let progress = discovery.scanProgress {
            HStack {
                ProgressView(value: progress.fraction) {
                    Text("Checked \(progress.done) of \(progress.total) addresses")
                        .font(.caption)
                }
                Button("Stop") { discovery.stopScan() }
            }
        } else {
            HStack {
                Text(discovery.subnets.map { "\($0.scannedRange) (\($0.interface))" }.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(discovery.hasScanned ? "Scan Again" : "Scan Network") { discovery.scan() }
            }
        }
    }
}

private struct TailscaleControls: View {
    let discovery: DiscoveryModel
    @State private var token = ""

    var body: some View {
        if discovery.hasTailscaleToken {
            HStack {
                if let progress = discovery.tailscaleProgress {
                    if progress.total == 0 {
                        ProgressView().controlSize(.small)
                        Text("Listing tailnet machines…").font(.caption)
                    } else {
                        ProgressView(value: progress.fraction) {
                            Text("Checked \(progress.done) of \(progress.total) Linux machines").font(.caption)
                        }
                    }
                } else {
                    Text("Probes your tailnet's online Linux machines.").foregroundStyle(.secondary)
                    Spacer()
                    Button(discovery.hasCheckedTailscale ? "Check Again" : "Check Tailscale") { discovery.checkTailscale() }
                }
                Menu {
                    Button("Forget API Token", role: .destructive) { discovery.forgetTailscaleToken() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SecureField("API access token", text: $token, prompt: Text("tskey-api-…"))
                        .onSubmit(save)
                    Button("Save", action: save).disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 4) {
                    Text("The app is sandboxed and can't ask the Tailscale app directly, so it uses the Tailscale API. The token is kept in your Keychain.")
                    Link("Create a token", destination: URL(string: "https://login.tailscale.com/admin/settings/keys")!)
                }
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let error = discovery.tailscaleError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        discovery.saveTailscaleToken(token)
        token = ""
    }
}
