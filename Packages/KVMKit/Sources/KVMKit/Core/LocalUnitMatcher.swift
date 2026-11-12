import Foundation

/// Decides which saved device each plugged-in USB KVM is, so a unit keeps
/// its name (and settings) when it is unplugged, plugged back in or the app
/// restarts.
public enum LocalUnitMatcher {
    /// A saved device that stands for a USB KVM.
    public struct Saved: Hashable, Sendable {
        public let deviceID: UUID
        /// The video capture device's unique ID when it was last seen. It
        /// includes the USB location, so it changes when the unit moves port.
        public let unitID: String?
        /// The unit's USB serial number, if it has one.
        public let serialNumber: String?

        public init(deviceID: UUID, unitID: String?, serialNumber: String?) {
            self.deviceID = deviceID
            self.unitID = unitID
            self.serialNumber = serialNumber
        }
    }

    /// A unit plugged in now.
    public struct Plugged: Hashable, Sendable {
        public let unitID: String
        public let serialNumber: String?

        public init(unitID: String, serialNumber: String?) {
            self.unitID = unitID
            self.serialNumber = serialNumber
        }
    }

    /// Pairs saved devices with plugged-in units, as device ID to index in
    /// `plugged`. Units left out are new.
    ///
    /// 1. The same USB serial number, when it is unique among the plugged units
    ///    (some capture chips report one shared serial number).
    /// 2. The same unit ID, which means the same USB port.
    /// 3. One saved device and one unit left over, neither with a serial
    ///    number: the unit moved to another port.
    public static func assign(saved: [Saved], plugged: [Plugged]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var taken = Set<Int>()

        func claim(_ device: UUID, _ index: Int) {
            result[device] = index
            taken.insert(index)
        }

        let serialCounts = Dictionary(plugged.compactMap(\.serialNumber).map { ($0, 1) }, uniquingKeysWith: +)
        for s in saved {
            guard let serial = s.serialNumber, serialCounts[serial] == 1,
                  let i = plugged.firstIndex(where: { $0.serialNumber == serial }), !taken.contains(i) else { continue }
            claim(s.deviceID, i)
        }
        for s in saved where result[s.deviceID] == nil {
            guard let id = s.unitID, let i = plugged.firstIndex(where: { $0.unitID == id }), !taken.contains(i) else { continue }
            claim(s.deviceID, i)
        }
        let leftSaved = saved.filter { result[$0.deviceID] == nil && $0.serialNumber == nil }
        let leftPlugged = plugged.indices.filter { !taken.contains($0) && plugged[$0].serialNumber == nil }
        if leftSaved.count == 1, leftPlugged.count == 1 {
            claim(leftSaved[0].deviceID, leftPlugged[0])
        }
        return result
    }

    /// A name for a newly found unit that no saved device uses yet:
    /// "Openterface", then "Openterface 2" and so on.
    public static func newName(base: String = "Openterface", taken: [String]) -> String {
        let names = Set(taken)
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
