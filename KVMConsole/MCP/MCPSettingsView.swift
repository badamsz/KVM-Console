import AppKit
import KVMKit
import SwiftUI

/// Settings > AI Agents: the MCP server's switch, port, token and the
/// commands that connect Claude and other MCP clients.
struct MCPSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var portText = ""
    @State private var showToken = false
    @State private var confirmNewToken = false

    private var mcp: MCPController { model.mcp }

    var body: some View {
        @Bindable var mcp = model.mcp
        Form {
            Section {
                Toggle("Let AI agents use KVM Console", isOn: Binding(get: { mcp.enabled }, set: { mcp.setEnabled($0) }))
                statusRow
            } footer: {
                Text("Runs an MCP server that Claude Code, Claude Desktop and other MCP clients on this Mac can connect to. It only accepts connections from this Mac, and only with the token below.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Allow control", isOn: $mcp.allowControl)
            } footer: {
                Text(mcp.allowControl
                     ? "Agents can type, press keys, switch Switch ports, mount and eject images, and ask to change power. Every power action asks you here first."
                     : "Agents can only list machines, read their status and take screenshots.")
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent("Address") {
                    Text(mcp.endpointURL).textSelection(.enabled).font(.callout.monospaced())
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("Port", text: $portText)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        if UInt16(portText) != mcp.port {
                            Button("Apply", action: applyPort).disabled(UInt16(portText).map { $0 < 1024 } ?? true)
                        }
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(showToken ? mcp.token : String(repeating: "•", count: 16))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("New…") { confirmNewToken = true }
                    }
                }
            }

            Section {
                CommandRow(title: "Claude Code", command: claudeCodeCommand)
                CommandRow(title: "Claude Desktop (claude_desktop_config.json)", command: claudeDesktopConfig)
            } header: {
                Text("Connect a client")
            } footer: {
                Text("Claude Desktop reaches the server through mcp-remote, which needs Node.js. Other clients: use the address above with the header Authorization: Bearer <token>.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if mcp.activity.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(mcp.activity.prefix(20)) { entry in
                        ActivityRow(entry: entry)
                    }
                    Button("Clear") { mcp.clearActivity() }
                }
            } header: {
                Text("Recent requests")
            }

            Section {
                Button("About AI Agents…") { HelpCenter.shared.show("ai-agents", using: openWindow) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            mcp.loadToken()
            portText = String(mcp.port)
        }
        .confirmationDialog("Make a new token?", isPresented: $confirmNewToken) {
            Button("New Token", role: .destructive) { mcp.regenerateToken() }
        } message: {
            Text("Clients set up with the current token stop working until you give them the new one.")
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch mcp.status {
        case .off:
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "circle.dotted").foregroundStyle(.secondary)
        case .listening(let port):
            Label("Listening on 127.0.0.1:\(String(port))", systemImage: "circle.fill").foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port >= 1024 else {
            portText = String(mcp.port)
            return
        }
        mcp.setPort(port)
    }

    private var claudeCodeCommand: String {
        "claude mcp add --transport http kvm-console \(mcp.endpointURL) --header \"Authorization: Bearer \(mcp.token)\""
    }

    private var claudeDesktopConfig: String {
        """
        {
          "mcpServers": {
            "kvm-console": {
              "command": "npx",
              "args": ["-y", "mcp-remote", "\(mcp.endpointURL)", "--header", "Authorization:${KVM_CONSOLE_AUTH}"],
              "env": { "KVM_CONSOLE_AUTH": "Bearer \(mcp.token)" }
            }
          }
        }
        """
    }
}

/// A command to copy, shown without revealing the token.
private struct CommandRow: View {
    let title: String
    let command: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
        }
    }
}

private struct ActivityRow: View {
    let entry: MCPController.Activity

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: entry.failed ? "xmark.circle" : "checkmark.circle")
                .foregroundStyle(entry.failed ? Color.orange : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.machine.map { "\(entry.tool) · \($0)" } ?? entry.tool)
                if entry.failed {
                    Text(entry.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Text(entry.date, style: .time).font(.caption).foregroundStyle(.secondary)
        }
    }
}
