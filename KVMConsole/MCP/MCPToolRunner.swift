import AppKit
import Foundation
import KVMKit

/// Runs the MCP server's tools (`KVMTool`) against the app's devices. Every
/// tool works through the same sessions and consoles the windows use, so
/// what an agent does shows up in the app.
@MainActor
struct MCPToolRunner {
    let app: AppModel
    let confirmer: MCPConfirmer

    /// A problem worth telling the model about, in words it can act on.
    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct Machine {
        let device: Device
        let target: Target
        var selection: TargetSelection { TargetSelection(deviceID: device.id, targetID: target.id) }
        /// "Server 3 (port 3 of Rack KVM)" or just the name.
        var label: String {
            target.switchPort == nil || device.targets.count == 1 ? target.name : "\(target.name) on \(device.name)"
        }
    }

    static let maxTextLength = 10_000

    func run(_ tool: KVMTool, _ arguments: [String: JSONValue]) async -> MCPToolResult {
        do {
            switch tool {
            case .listMachines: return listMachines()
            case .getMachineStatus: return try await status(of: resolve(arguments))
            case .takeScreenshot: return try await screenshot(of: resolve(arguments))
            case .switchToMachine: return try await switchTo(resolve(arguments))
            case .typeText: return try await typeText(on: resolve(arguments), arguments)
            case .pressKeys: return try await pressKeys(on: resolve(arguments), arguments)
            case .mountImage: return try await mount(on: resolve(arguments), arguments)
            case .ejectImage: return try await eject(from: resolve(arguments))
            case .power: return try await power(resolve(arguments), arguments)
            }
        } catch is CancellationError {
            return .error("Cancelled.")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: Finding machines

    private var allMachines: [Machine] {
        app.devices.flatMap { device in device.targets.map { Machine(device: device, target: $0) } }
    }

    /// The machine an argument names: a machine id, the id of a device with
    /// one machine, or an exact (case-insensitive) name.
    func resolve(_ arguments: [String: JSONValue]) throws -> Machine {
        guard let ref = arguments["machine"]?.stringValue?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw Failure("Say which machine: pass its id or name from list_machines as \"machine\".")
        }
        return try resolve(ref)
    }

    func resolve(_ ref: String) throws -> Machine {
        let machines = allMachines
        if let id = UUID(uuidString: ref) {
            if let m = machines.first(where: { $0.target.id == id }) { return m }
            let ofDevice = machines.filter { $0.device.id == id }
            if ofDevice.count == 1 { return ofDevice[0] }
            if ofDevice.count > 1 {
                throw Failure("That id is a device with \(ofDevice.count) machines. Use one machine's id from list_machines.")
            }
        }
        let named = machines.filter { $0.target.name.caseInsensitiveCompare(ref) == .orderedSame }
        if named.count == 1 { return named[0] }
        if named.count > 1 { throw Failure("Several machines are named \(ref). Use the machine's id from list_machines.") }
        let devices = machines.filter { $0.device.name.caseInsensitiveCompare(ref) == .orderedSame }
        if devices.count == 1 { return devices[0] }
        throw Failure("There's no machine called \(ref). Call list_machines to see the machines and their ids.")
    }

    /// For the activity list in Settings.
    func machineName(for ref: String) -> String? {
        (try? resolve(ref))?.label ?? ref
    }

    // MARK: Connecting

    /// The machine's device session, connected.
    private func connected(_ m: Machine) async throws -> DeviceSession {
        let session = app.session(for: m.device.id)
        await session.connectIfNeeded()
        // Someone else may have started connecting; wait for them.
        let deadline = Date().addingTimeInterval(30)
        while session.status == .connecting, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        switch session.status {
        case .connected: return session
        case .failed(let message): throw Failure("Couldn't connect to \(m.device.name): \(message)")
        default: throw Failure("Couldn't connect to \(m.device.name).")
        }
    }

    /// Behind a Switch, the screen, keyboard and virtual drive belong to the
    /// active port. Refuses rather than act on a different machine.
    private func requireOnScreen(_ m: Machine, _ session: DeviceSession) async throws {
        guard let port = m.target.switchPort else { return }
        if session.switchState == nil { await session.refresh(.switchPorts) }
        guard !session.isOnScreen(m.target) else { return }
        let active = session.switchState?.activePort
        let activeName = active.flatMap { p in m.device.targets.first { $0.switchPort == p }?.name }
        let current = activeName.map { " (now \($0))" } ?? ""
        throw Failure("\(m.target.name) is on Switch port \(portLabel(port, session)), which isn't the active port\(current). Call switch_to_machine first.")
    }

    private func portLabel(_ port: Int, _ session: DeviceSession?) -> String {
        session?.switchState?.ports.first { $0.index == port }?.displayID ?? String(port + 1)
    }

    /// A live console window for the machine, opened if needed. Keyboard
    /// input goes through it, so the person can watch.
    private func liveConsole(_ m: Machine) async throws -> ConsoleModel {
        func ready(_ c: ConsoleModel?) -> ConsoleModel? {
            guard let c, c.input != nil, c.state == .live || c.state == .noSignal else { return nil }
            return c
        }
        if let c = ready(app.console(for: m.selection)) { return c }
        if app.console(for: m.selection) == nil {
            guard app.openConsole(m.selection) else {
                throw Failure("KVM Console can't open a console window yet. Ask the person to open KVM Console's main window once, then try again.")
            }
        }
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
            if let c = ready(app.console(for: m.selection)) {
                // Give a fresh connection a moment to settle before typing.
                try await Task.sleep(nanoseconds: 300_000_000)
                return c
            }
        }
        if case .failed(let message)? = app.console(for: m.selection)?.state {
            throw Failure("The console for \(m.label) didn't connect: \(message)")
        }
        throw Failure("The console for \(m.label) didn't connect within 25 seconds.")
    }

    // MARK: Read-only tools

    private func listMachines() -> MCPToolResult {
        var devices: [JSONValue] = []
        for device in app.devices {
            let session = app.sessions[device.id]
            var machines: [JSONValue] = []
            for target in device.targets {
                var m: [String: JSONValue] = [
                    "id": .string(target.id.uuidString),
                    "name": .string(target.name),
                    "mouse_mode": .string(target.mouseMode.rawValue),
                    "console_open": .bool(app.console(for: TargetSelection(deviceID: device.id, targetID: target.id)) != nil),
                ]
                if let port = target.switchPort {
                    m["switch_port"] = .string(portLabel(port, session))
                    if session?.switchState != nil { m["on_screen"] = .bool(session?.isOnScreen(target) ?? false) }
                } else {
                    m["on_screen"] = true
                }
                if let leds = session?.leds(for: target) {
                    m["power_light"] = .bool(leds.power)
                    m["hdd_light"] = .bool(leds.hdd)
                }
                machines.append(.object(m))
            }
            var d: [String: JSONValue] = [
                "id": .string(device.id.uuidString),
                "name": .string(device.name),
                "model": .string(device.model.displayName),
                "connection": .string(connectionText(session)),
                "machines": .array(machines),
            ]
            if device.family.isLocal {
                d["plugged_in"] = .bool(app.pluggedUnits[device.id] != nil)
            }
            devices.append(.object(d))
        }
        if devices.isEmpty {
            return .text("No devices are set up in KVM Console yet. The person can add one with File > Add Device.")
        }
        return .json(["devices": .array(devices)])
    }

    private func connectionText(_ session: DeviceSession?) -> String {
        switch session?.status {
        case .connected(let label, let host)?: return "connected via \(label) (\(host))"
        case .connecting?: return "connecting"
        case .failed(let message)?: return "failed: \(message)"
        case .idle?, nil: return "not connected yet (get_machine_status connects)"
        }
    }

    private func status(of m: Machine) async throws -> MCPToolResult {
        let session = try await connected(m)
        await session.refreshAll()
        var out: [String: JSONValue] = [
            "machine": .string(m.target.name),
            "machine_id": .string(m.target.id.uuidString),
            "device": .string(m.device.name),
            "model": .string(m.device.model.displayName),
            "connection": .string(connectionText(session)),
            "on_screen": .bool(session.isOnScreen(m.target)),
            "console_open": .bool(app.console(for: m.selection) != nil),
        ]
        if let port = m.target.switchPort {
            out["switch_port"] = .string(portLabel(port, session))
            if let active = session.switchState?.activePort {
                out["active_switch_port"] = .string(portLabel(active, session))
            }
        }
        if let leds = session.leds(for: m.target) {
            out["power"] = [
                "available": true,
                "power_light": .bool(leds.power),
                "hdd_light": .bool(leds.hdd),
                "busy": .bool(session.atxBusy(for: m.target)),
            ]
        } else {
            out["power"] = ["available": false, "note": "This machine has no ATX power control set up."]
        }
        if let msd = session.msd {
            var media: [String: JSONValue] = [
                "available": .bool(msd.enabled),
                "images": .array(msd.images.map { image in
                    JSONValue.object([
                        "name": .string(image.name),
                        "size_bytes": .number(Double(image.size)),
                        "complete": .bool(image.complete),
                    ])
                }),
            ]
            if let drive = msd.drive {
                var d: [String: JSONValue] = [
                    "connected": .bool(drive.connected),
                    "mode": .string(drive.cdrom ? "cdrom" : "flash"),
                    "writable": .bool(drive.writable),
                ]
                if let image = drive.image { d["image"] = .string(image.name) }
                media["drive"] = .object(d)
            }
            if let free = msd.freeBytes { media["free_bytes"] = .number(Double(free)) }
            if m.target.switchPort != nil {
                media["note"] = "Behind a Switch the virtual drive follows the active port."
            }
            out["virtual_media"] = .object(media)
        } else {
            out["virtual_media"] = ["available": false]
        }
        return .json(.object(out))
    }

    private func screenshot(of m: Machine) async throws -> MCPToolResult {
        let session = try await connected(m)
        try await requireOnScreen(m, session)
        var image: CGImage?
        // An open console already has a fresh frame (except in H.264 mode).
        if let console = app.console(for: m.selection), console.state == .live, let frame = console.frame {
            image = frame
        } else {
            guard let backend = session.backend else { throw Failure("Lost the connection to \(m.device.name).") }
            image = try await backend.screenshot().cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image, let jpeg = Self.jpeg(image) else {
            throw Failure("Couldn't read the screen picture from \(m.device.name).")
        }
        let time = Date().formatted(date: .omitted, time: .standard)
        return MCPToolResult(content: [
            .image(jpeg, mimeType: "image/jpeg"),
            .text("Screen of \(m.label) at \(time), \(image.width)×\(image.height) pixels."),
        ])
    }

    /// A JPEG no larger than `maxSide` on its longer edge.
    static func jpeg(_ image: CGImage, maxSide: Int = 1568) -> Data? {
        var source = image
        let longest = max(image.width, image.height)
        if longest > maxSide {
            let scale = Double(maxSide) / Double(longest)
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let scaled = ctx.makeImage() { source = scaled }
            }
        }
        return NSBitmapImageRep(cgImage: source).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

    // MARK: Control tools

    private func switchTo(_ m: Machine) async throws -> MCPToolResult {
        guard m.target.switchPort != nil else {
            return .text("\(m.label) isn't behind a Switch, so it's always on screen.")
        }
        let session = try await connected(m)
        if session.switchState == nil { await session.refresh(.switchPorts) }
        if session.isOnScreen(m.target) {
            return .text("\(m.label) is already the active port.")
        }
        try await session.activate(m.target)
        await session.refresh(.switchPorts)
        guard session.isOnScreen(m.target) else {
            throw Failure("Asked the Switch to change to \(m.label), but it still shows another port.")
        }
        return .text("\(m.label) is now the active port. Its screen, keyboard and the virtual drive go to it.")
    }

    private func typeText(on m: Machine, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard let raw = arguments["text"]?.stringValue else { throw Failure("Pass the text to type as \"text\".") }
        let text = TextPaste.normalize(raw)
        guard !text.isEmpty else { throw Failure("There's nothing to type.") }
        guard text.count <= Self.maxTextLength else {
            throw Failure("That's \(text.count) characters; type at most \(Self.maxTextLength) at a time.")
        }
        let session = try await connected(m)
        try await requireOnScreen(m, session)
        let console = try await liveConsole(m)
        let (skipped, limitation) = try await console.typeTextAndWait(text)
        if skipped > 0 {
            return .text("Typed \(text.count - skipped) of \(text.count) characters on \(m.label); \(skipped) couldn't be typed. \(limitation)"
                .trimmingCharacters(in: .whitespaces))
        }
        return .text("Typed \(text.count) characters on \(m.label).")
    }

    private func pressKeys(on m: Machine, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let names: [String]
        if let list = arguments["keys"]?.arrayValue {
            names = list.compactMap(\.stringValue)
            guard names.count == list.count else { throw Failure("\"keys\" must be a list of strings.") }
        } else if let one = arguments["keys"]?.stringValue {
            names = [one]
        } else {
            throw Failure("Pass the keys to press as \"keys\", such as [\"ctrl+alt+delete\"].")
        }
        guard !names.isEmpty, names.count <= 100 else { throw Failure("Pass between 1 and 100 key combinations.") }
        // Read them all before pressing any.
        let combos = try names.map { name in
            do { return try KeyCombo.parse(name) } catch { throw Failure("\(name): \(error.localizedDescription)") }
        }
        let delay = min(max(arguments["delay_ms"]?.intValue ?? 150, 0), 5000)

        let session = try await connected(m)
        try await requireOnScreen(m, session)
        let console = try await liveConsole(m)
        for (i, combo) in combos.enumerated() {
            try Task.checkCancellation()
            guard console.input != nil else { throw Failure("The console disconnected after \(i) of \(combos.count) key presses.") }
            console.sendCombo(combo)
            try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
        }
        return .text("Pressed \(names.joined(separator: ", ")) on \(m.label).")
    }

    private func mount(on m: Machine, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard let name = arguments["image"]?.stringValue, !name.isEmpty else {
            throw Failure("Pass the stored image's name as \"image\". get_machine_status lists them.")
        }
        let session = try await connected(m)
        try await requireOnScreen(m, session)
        await session.refreshMSD()
        guard let msd = session.msd, msd.enabled else {
            throw Failure("\(m.device.name) has no virtual drive, or it's turned off.")
        }
        let lower = name.lowercased()
        guard let image = msd.images.first(where: { $0.name == name })
            ?? msd.images.first(where: { $0.name.lowercased() == lower || ($0.name as NSString).lastPathComponent.lowercased() == lower })
        else {
            let names = msd.images.map(\.name).joined(separator: ", ")
            throw Failure("\(m.device.name) has no image named \(name). Stored images: \(names.isEmpty ? "none" : names).")
        }
        guard image.complete else { throw Failure("\(image.name) hasn't finished uploading.") }

        let mode: KVMTool.MediaMode
        if let raw = arguments["mode"]?.stringValue {
            guard let parsed = KVMTool.MediaMode(rawValue: raw) else { throw Failure("mode must be cdrom or flash.") }
            mode = parsed
        } else {
            mode = image.looksLikeCD ? .cdrom : .flash
        }
        if mode == .cdrom, !image.cdromable {
            throw Failure("\(m.device.name) can't present \(image.name) as a CD/DVD. Use mode flash.")
        }
        let writable = mode == .flash && (arguments["writable"]?.boolValue ?? false)
        if writable, !m.device.family.supportsWritableImages {
            throw Failure("\(m.device.model.shortName) can't make images writable.")
        }
        try await session.mountMedia(image: image.name, cdrom: mode == .cdrom, writable: writable)
        let how = mode == .cdrom ? "a CD/DVD" : (writable ? "a writable flash drive" : "a read-only flash drive")
        return .text("Mounted \(image.name) on \(m.label) as \(how) and connected the drive.")
    }

    private func eject(from m: Machine) async throws -> MCPToolResult {
        let session = try await connected(m)
        try await requireOnScreen(m, session)
        guard session.msd != nil else { throw Failure("\(m.device.name) has no virtual drive.") }
        try await session.ejectMedia()
        return .text("Disconnected the virtual drive from \(m.label).")
    }

    private func power(_ m: Machine, _ arguments: [String: JSONValue]) async throws -> MCPToolResult {
        guard let raw = arguments["action"]?.stringValue, let action = KVMTool.PowerAction(rawValue: raw) else {
            throw Failure("action must be one of: on, shut_down, reset, force_off.")
        }
        let session = try await connected(m)
        if m.target.switchPort != nil { await session.refresh(.switchPorts) } else { await session.refresh(.atx) }
        guard let leds = session.leds(for: m.target) else {
            throw Failure("\(m.label) has no ATX power control, so its power can't be changed from here.")
        }
        guard !session.atxBusy(for: m.target) else {
            throw Failure("A power action is still running on \(m.label). Try again in a few seconds.")
        }
        let command: PowerCommand
        switch action {
        case .on: command = .powerOn
        case .shutDown: command = .shutDown
        case .reset: command = .reset
        case .forceOff: command = .forceOff
        }
        guard command.isEnabled(poweredOn: leds.power) else {
            return .text("\(m.label) is already \(leds.power ? "on" : "off"); nothing to do.")
        }

        let verb: String
        switch command {
        case .powerOn: verb = "turn on"
        case .shutDown: verb = "shut down"
        case .reset: verb = "reset"
        case .forceOff: verb = "force off"
        }
        let detail = command.confirmation?.message ?? (command == .shutDown
            ? "This presses the power button briefly so the operating system can shut down."
            : "This presses the power button.")
        let answer = await confirmer.ask(
            title: "Allow an AI agent to \(verb) \(m.label)?",
            message: "An app connected to KVM Console's MCP server asked to \(verb) \(m.label) on \(m.device.name). \(detail)",
            allowTitle: command.title)
        switch answer {
        case .allowed: break
        case .declined: throw Failure("The person at the Mac declined to \(verb) \(m.label). Don't retry unless they ask.")
        case .timedOut: throw Failure("Nobody answered the request to \(verb) \(m.label) within two minutes, so nothing was done.")
        case .busy: throw Failure("Another request is waiting for the person to answer. Try again after it.")
        }
        try await command.perform(on: session, for: m.target)
        return .text("Sent \(command.title) to \(m.label). Check the power light with get_machine_status in a few seconds.")
    }
}
