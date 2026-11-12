import KVMKit
import SwiftUI

/// The power actions offered for a machine with ATX. The detail page, the
/// console toolbar and the menu bar all build their controls from this list,
/// so names, confirmations and enabled states match everywhere.
enum PowerCommand: String, CaseIterable, Identifiable {
    case powerOn
    case shutDown
    case reset
    case forceOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .powerOn: return "Power On"
        case .shutDown: return "Shut Down"
        case .reset: return "Reset"
        case .forceOff: return "Force Off"
        }
    }

    /// The title in a menu, with "…" when the action asks first.
    var menuTitle: String { confirmation == nil ? title : title + "…" }

    /// Whether the action makes sense in the current power state.
    func isEnabled(poweredOn: Bool) -> Bool {
        switch self {
        case .powerOn: return !poweredOn
        case .shutDown: return poweredOn
        case .reset, .forceOff: return true
        }
    }

    /// Actions that may lose work ask first.
    struct Confirmation {
        let title: (String) -> String
        let message: String
    }

    var confirmation: Confirmation? {
        switch self {
        case .powerOn, .shutDown:
            return nil
        case .reset:
            return Confirmation(title: { "Reset \($0)?" },
                                message: "This presses the reset button and may lose unsaved work.")
        case .forceOff:
            return Confirmation(title: { "Force off \($0)?" },
                                message: "This holds the power button and may lose unsaved work.")
        }
    }

    var isDestructive: Bool { confirmation != nil }

    @MainActor
    func perform(on session: DeviceSession, for target: Target) async throws {
        switch self {
        case .powerOn: try await session.power(.on, for: target)
        case .shutDown: try await session.power(.off, for: target)
        case .reset: try await session.click(.reset, for: target)
        case .forceOff: try await session.power(.offHard, for: target)
        }
    }
}

/// A power or disk-activity light.
struct StatusLight: View {
    let on: Bool
    var color: Color = .green
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(on ? color : Color.secondary.opacity(0.3)).frame(width: size, height: size)
    }
}

extension View {
    /// Asks before running a `PowerCommand` that needs confirming. Bind
    /// `pending` to the command waiting for an answer.
    func powerConfirmation(_ pending: Binding<PowerCommand?>, machine: String,
                           run: @escaping (PowerCommand) -> Void) -> some View {
        confirmationDialog(
            pending.wrappedValue?.confirmation?.title(machine) ?? "",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { command in
            Button(command.title, role: .destructive) { run(command) }
        } message: { command in
            Text(command.confirmation?.message ?? "")
        }
    }
}
