import Foundation

/// The tools KVM Console's MCP server offers. The app runs them
/// (`MCPToolRunner`); this is only their names, descriptions and schemas.
public enum KVMTool: String, CaseIterable, Sendable {
    case listMachines = "list_machines"
    case getMachineStatus = "get_machine_status"
    case takeScreenshot = "take_screenshot"
    case switchToMachine = "switch_to_machine"
    case typeText = "type_text"
    case pressKeys = "press_keys"
    case mountImage = "mount_image"
    case ejectImage = "eject_image"
    case power = "power"

    public var kind: MCPToolKind {
        switch self {
        case .listMachines, .getMachineStatus, .takeScreenshot: return .read
        case .switchToMachine, .typeText, .pressKeys, .mountImage, .ejectImage: return .control
        case .power: return .power
        }
    }

    /// The tools to offer. Control and power tools only when the person allowed them.
    public static func offered(allowControl: Bool) -> [MCPTool] {
        allCases.filter { allowControl || $0.kind == .read }.map(\.definition)
    }

    /// Power actions the `power` tool takes.
    public enum PowerAction: String, CaseIterable, Sendable {
        case on
        case shutDown = "shut_down"
        case reset
        case forceOff = "force_off"
    }

    public enum MediaMode: String, CaseIterable, Sendable {
        case cdrom
        case flash
    }

    /// Server instructions sent at initialize, which the client may show the model.
    public static let instructions = """
    KVM Console controls computers ("machines") through KVM-over-IP devices: PiKVM (optionally with a PiKVM Switch \
    that has several machines on ports), Sipeed NanoKVM, and Openterface USB KVMs plugged into the Mac.
    Start with list_machines. Refer to a machine by its id, or by its exact name.
    Behind a PiKVM Switch only the active port's machine is on screen: the screenshot, keyboard and virtual drive all \
    follow the active port, so call switch_to_machine first. Tools that act on a machine that isn't on screen fail \
    instead of reaching the wrong machine.
    Keyboard input opens a console window on the Mac, so the person can watch. Typing uses the remote machine's \
    keyboard layout as configured on the device. Take a screenshot after acting to check the result.
    Every power action asks the person at the Mac to confirm, and fails if they decline or don't answer.
    """

    static let machineProperty: JSONValue = [
        "type": "string",
        "description": "The machine's id from list_machines, or its exact name.",
    ]

    static func schema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { JSONValue.string($0) }),
            "additionalProperties": false,
        ]
    }

    public var definition: MCPTool {
        switch self {
        case .listMachines:
            return MCPTool(
                name: rawValue, title: "List machines",
                description: "Lists the KVM devices set up in KVM Console and the machines each one controls, with ids, model, Switch port, whether the machine is on screen, connection status and power light when known.",
                inputSchema: Self.schema([:], required: []), kind: kind)
        case .getMachineStatus:
            return MCPTool(
                name: rawValue, title: "Get machine status",
                description: "Connects to a machine's KVM if needed and reports its power and disk lights, whether it is on screen, the Switch's active port, and the virtual drive: what is mounted and which images are stored.",
                inputSchema: Self.schema(["machine": Self.machineProperty], required: ["machine"]), kind: kind)
        case .takeScreenshot:
            return MCPTool(
                name: rawValue, title: "Take screenshot",
                description: "Returns a picture of the machine's screen. Behind a PiKVM Switch the machine must be on the active port.",
                inputSchema: Self.schema(["machine": Self.machineProperty], required: ["machine"]), kind: kind)
        case .switchToMachine:
            return MCPTool(
                name: rawValue, title: "Switch to machine",
                description: "Makes a machine behind a PiKVM Switch the active port, so its screen, keyboard and the virtual drive go to it. Does nothing for a machine that has no Switch or is already active.",
                inputSchema: Self.schema(["machine": Self.machineProperty], required: ["machine"]), kind: kind)
        case .typeText:
            return MCPTool(
                name: rawValue, title: "Type text",
                description: "Types text on the machine as key presses. A newline is typed as Enter. Opens the machine's console window on the Mac if it isn't open. Returns when typing is done.",
                inputSchema: Self.schema([
                    "machine": Self.machineProperty,
                    "text": ["type": "string", "description": "The text to type, at most 10,000 characters."],
                ], required: ["machine", "text"]), kind: kind)
        case .pressKeys:
            return MCPTool(
                name: rawValue, title: "Press keys",
                description: "Presses keys or key combinations in order, such as [\"ctrl+alt+delete\"], [\"f2\"] or [\"down\", \"down\", \"enter\"]. Within a combination, keys are pressed in order and released in reverse. Opens the machine's console window on the Mac if it isn't open.",
                inputSchema: Self.schema([
                    "machine": Self.machineProperty,
                    "keys": [
                        "type": "array", "minItems": 1, "maxItems": 100,
                        "items": ["type": "string"],
                        "description": "Combinations joined with +: modifiers ctrl, alt, shift, meta (Windows/Command key); keys enter, esc, tab, space, backspace, delete, insert, home, end, pageup, pagedown, up, down, left, right, f1–f12, a–z, 0–9, punctuation, or web key codes such as KeyA.",
                    ],
                    "delay_ms": ["type": "integer", "minimum": 0, "maximum": 5000,
                                 "description": "Pause between combinations in milliseconds. Default 150."],
                ], required: ["machine", "keys"]), kind: kind)
        case .mountImage:
            return MCPTool(
                name: rawValue, title: "Mount image",
                description: "Puts an image already stored on the KVM into its virtual drive and connects the drive to the machine, as a CD/DVD or as a flash drive. Use get_machine_status to see the stored images.",
                inputSchema: Self.schema([
                    "machine": Self.machineProperty,
                    "image": ["type": "string", "description": "The stored image's name, as get_machine_status lists it."],
                    "mode": ["type": "string", "enum": .array(MediaMode.allCases.map { JSONValue.string($0.rawValue) }),
                             "description": "cdrom (default for .iso) or flash."],
                    "writable": ["type": "boolean", "description": "Let the machine write to a flash-mode image. Default false."],
                ], required: ["machine", "image"]), kind: kind)
        case .ejectImage:
            return MCPTool(
                name: rawValue, title: "Eject image",
                description: "Disconnects the virtual drive from the machine.",
                inputSchema: Self.schema(["machine": Self.machineProperty], required: ["machine"]), kind: kind)
        case .power:
            return MCPTool(
                name: rawValue, title: "Power",
                description: "Changes a machine's power through its ATX connection: on, shut_down (a short press of the power button, so the OS can shut down), reset (the reset button), or force_off (holds the power button). The person at the Mac is asked to confirm first; if they decline or don't answer within two minutes, nothing happens.",
                inputSchema: Self.schema([
                    "machine": Self.machineProperty,
                    "action": ["type": "string", "enum": .array(PowerAction.allCases.map { JSONValue.string($0.rawValue) })],
                ], required: ["machine", "action"]), kind: kind)
        }
    }
}
