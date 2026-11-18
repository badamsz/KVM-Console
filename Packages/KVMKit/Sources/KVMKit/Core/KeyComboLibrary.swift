import Foundation

/// A titled group of key combinations, shown as a section of a menu.
public struct KeyComboGroup: Identifiable, Sendable {
    public let title: String
    public let items: [KeyComboItem]
    public var id: String { title }
}

/// Built-in key combinations for each operating system, for the Send Keys
/// menu. Most are ones macOS would keep for itself if typed in the console
/// (⌘Tab, ⌃⌘Q, Ctrl+Alt+Del), or that are hard to type there.
public enum KeyComboLibrary {
    public static func groups(for os: TargetOS) -> [KeyComboGroup] {
        switch os {
        case .windows: return windows
        case .macOS: return macOS
        case .linux: return linux
        }
    }

    public static var all: [KeyComboItem] {
        TargetOS.allCases.flatMap { groups(for: $0).flatMap(\.items) }
    }

    /// Seconds between the steps of a Magic SysRq sequence, so each one
    /// (syncing disks in particular) has time to finish.
    public static let sysRqStepDelay = 2.0

    static let windows: [KeyComboGroup] = [
        group("System", .windows, [
            ("Security Options", "ctrl+alt+delete"),
            ("Task Manager", "ctrl+shift+esc"),
            ("Lock", "win+l"),
            ("Run", "win+r"),
            ("Quick Link Menu", "win+x"),
            ("Settings", "win+i"),
            ("Restart Graphics Driver", "win+ctrl+shift+b"),
            ("Setup Command Prompt / Context Menu", "shift+f10"),
        ]),
        group("Windows and Apps", .windows, [
            ("Start Menu", "win"),
            ("Switch Apps", "alt+tab"),
            ("Close Window", "alt+f4"),
            ("Show Desktop", "win+d"),
            ("Task View", "win+tab"),
            ("File Explorer", "win+e"),
            ("Maximize Window", "win+up"),
            ("Display Mode (Project)", "win+p"),
            ("Switch Keyboard Layout", "win+space"),
        ]),
        group("Screenshots", .windows, [
            ("Print Screen", "printscreen"),
            ("Snip a Region", "win+shift+s"),
        ]),
    ]

    static let macOS: [KeyComboGroup] = [
        group("System", .macOS, [
            ("Force Quit Apps", "cmd+opt+esc"),
            ("Lock Screen", "ctrl+cmd+q"),
            ("Log Out", "shift+cmd+q"),
            ("Spotlight", "cmd+space"),
            ("Mission Control", "ctrl+up"),
            ("Next Input Source", "ctrl+space"),
        ]),
        group("Apps and Windows", .macOS, [
            ("Switch Apps", "cmd+tab"),
            ("Switch Windows of App", "cmd+`"),
            ("Quit App", "cmd+q"),
            ("Close Window", "cmd+w"),
            ("Hide App", "cmd+h"),
            ("Minimize Window", "cmd+m"),
            ("Full Screen", "ctrl+cmd+f"),
            ("App Settings", "cmd+,"),
        ]),
        group("Screenshots", .macOS, [
            ("Screenshot", "shift+cmd+3"),
            ("Screenshot of Selection", "shift+cmd+4"),
            ("Screenshot Options", "shift+cmd+5"),
        ]),
        group("Finder", .macOS, [
            ("Go to Folder", "shift+cmd+g"),
            ("Show Hidden Files", "shift+cmd+."),
        ]),
    ]

    static let linux: [KeyComboGroup] = [
        group("Virtual Consoles", .linux, (1...7).map { ("Switch to tty\($0)", "ctrl+alt+f\($0)") }),
        group("Desktop", .linux, [
            ("Activities / App Menu", "super"),
            ("Lock Screen", "super+l"),
            ("Terminal", "ctrl+alt+t"),
            ("Run Command", "alt+f2"),
            ("Switch Apps", "alt+tab"),
            ("Close Window", "alt+f4"),
            ("Log Out / Reboot", "ctrl+alt+delete"),
            ("Kill X Server (if enabled)", "ctrl+alt+backspace"),
            ("Screenshot", "printscreen"),
        ]),
        KeyComboGroup(title: "Magic SysRq", items: [
            KeyComboItem(name: "Safe Reboot (REISUB)",
                         keys: "alt+sysrq+r, alt+sysrq+e, alt+sysrq+i, alt+sysrq+s, alt+sysrq+u, alt+sysrq+b",
                         os: .linux, stepDelay: sysRqStepDelay),
            KeyComboItem(name: "Safe Power Off (REISUO)",
                         keys: "alt+sysrq+r, alt+sysrq+e, alt+sysrq+i, alt+sysrq+s, alt+sysrq+u, alt+sysrq+o",
                         os: .linux, stepDelay: sysRqStepDelay),
        ] + items(.linux, [
            ("Help (to the Kernel Log)", "alt+sysrq+h"),
            ("Sync Disks", "alt+sysrq+s"),
            ("Remount Read-Only", "alt+sysrq+u"),
            ("Terminate All Processes", "alt+sysrq+e"),
            ("Kill All Processes", "alt+sysrq+i"),
            ("Run OOM Killer", "alt+sysrq+f"),
            ("Kill Console Programs (SAK)", "alt+sysrq+k"),
            ("Reboot Immediately", "alt+sysrq+b"),
            ("Power Off Immediately", "alt+sysrq+o"),
        ])),
    ]

    private static func group(_ title: String, _ os: TargetOS, _ entries: [(String, String)]) -> KeyComboGroup {
        KeyComboGroup(title: title, items: items(os, entries))
    }

    private static func items(_ os: TargetOS, _ entries: [(String, String)]) -> [KeyComboItem] {
        entries.map { KeyComboItem(name: $0.0, keys: $0.1, os: os) }
    }
}
