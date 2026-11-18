import XCTest
@testable import KVMKit

final class KeyComboItemTests: XCTestCase {
    func testSingleStep() throws {
        XCTAssertEqual(try KeyComboItem.parseSteps("ctrl+alt+delete"), [["ControlLeft", "AltLeft", "Delete"]])
    }

    func testSequenceSplitsAtCommas() throws {
        XCTAssertEqual(try KeyComboItem.parseSteps("alt+sysrq+s, alt+sysrq+b"),
                       [["AltLeft", "PrintScreen", "KeyS"], ["AltLeft", "PrintScreen", "KeyB"]])
        XCTAssertEqual(try KeyComboItem.parseSteps("f2,enter"), [["F2"], ["Enter"]])
        // A trailing comma is not an empty step.
        XCTAssertEqual(try KeyComboItem.parseSteps("f2, "), [["F2"]])
    }

    func testCommaKey() throws {
        XCTAssertEqual(try KeyComboItem.parseSteps("cmd+,"), [["MetaLeft", "Comma"]])
        XCTAssertEqual(try KeyComboItem.parseSteps(","), [["Comma"]])
        XCTAssertEqual(try KeyComboItem.parseSteps("cmd+,, enter"), [["MetaLeft", "Comma"], ["Enter"]])
        XCTAssertEqual(try KeyComboItem.parseSteps("ctrl+comma"), [["ControlLeft", "Comma"]])
    }

    func testErrorsNameTheStep() {
        XCTAssertThrowsError(try KeyComboItem.parseSteps("")) { error in
            XCTAssertEqual(error as? KeyComboItem.StepError, .step(0, .empty))
        }
        XCTAssertThrowsError(try KeyComboItem.parseSteps("f2, ctrl+bogus")) { error in
            XCTAssertEqual(error as? KeyComboItem.StepError, .step(1, .unknownKey("bogus")))
            XCTAssertTrue(error.localizedDescription.hasPrefix("Step 2:"))
        }
        let tooMany = Array(repeating: "a", count: KeyComboItem.maxSteps + 1).joined(separator: ",")
        XCTAssertThrowsError(try KeyComboItem.parseSteps(tooMany))
    }

    func testLabels() {
        let cad = ["ControlLeft", "AltLeft", "Delete"]
        XCTAssertEqual(KeyComboLabel.label(cad, os: .windows), "Ctrl+Alt+Del")
        XCTAssertEqual(KeyComboLabel.label(["MetaLeft", "KeyL"], os: .windows), "Win+L")
        XCTAssertEqual(KeyComboLabel.label(["MetaLeft", "KeyL"], os: .linux), "Super+L")
        XCTAssertEqual(KeyComboLabel.label(["MetaLeft", "AltLeft", "Escape"], os: .macOS), "⌥⌘Esc")
        XCTAssertEqual(KeyComboLabel.label(["ShiftLeft", "MetaLeft", "Digit3"], os: .macOS), "⇧⌘3")
        XCTAssertEqual(KeyComboLabel.label(["MetaLeft", "ControlLeft", "KeyQ"], os: .macOS), "⌃⌘Q")
        XCTAssertEqual(KeyComboLabel.label(["AltLeft", "PrintScreen", "KeyB"], os: .linux), "Alt+SysRq+B")
        XCTAssertEqual(KeyComboLabel.label(["PrintScreen"], os: .linux), "PrtSc")
        XCTAssertEqual(KeyComboLabel.label([["F2"], ["Enter"]], os: nil), "F2, Enter")
    }

    func testMenuTitle() {
        XCTAssertEqual(KeyComboItem(name: "Lock", keys: "win+l", os: .windows).menuTitle, "Lock (Win+L)")
        XCTAssertEqual(KeyComboItem(name: "", keys: "ctrl+alt+f2").menuTitle, "Ctrl+Alt+F2")
        XCTAssertEqual(KeyComboItem(name: "Broken", keys: "ctrl+bogus").menuTitle, "Broken")
    }

    func testEveryLibraryComboIsSendable() throws {
        let library = KeyComboLibrary.all
        XCTAssertFalse(library.isEmpty)
        for os in TargetOS.allCases {
            XCTAssertFalse(KeyComboLibrary.groups(for: os).isEmpty, "\(os) has no combinations")
            for item in KeyComboLibrary.groups(for: os).flatMap(\.items) {
                XCTAssertEqual(item.os, os, item.name)
            }
        }
        for item in library {
            let steps = try item.steps()
            XCTAssertFalse(item.name.isEmpty)
            for step in steps {
                // A boot keyboard reports at most six keys besides modifiers.
                XCTAssertLessThanOrEqual(step.count, 6, item.name)
                for code in step {
                    XCTAssertTrue(KeyCombo.knownCodes.contains(code), "\(item.name): \(code)")
                    XCTAssertNotNil(HIDReport.usage(forWebCode: code), "\(item.name): \(code)")
                }
            }
        }
        XCTAssertEqual(Set(library.map(\.id)).count, library.count)
    }

    func testLibraryCoversTheBasics() throws {
        func keys(_ os: TargetOS) -> [[[String]]] {
            KeyComboLibrary.groups(for: os).flatMap(\.items).compactMap { try? $0.steps() }
        }
        XCTAssertTrue(keys(.windows).contains([["ControlLeft", "AltLeft", "Delete"]]))
        XCTAssertTrue(keys(.windows).contains([["MetaLeft", "KeyL"]]))
        XCTAssertTrue(keys(.macOS).contains([["MetaLeft", "AltLeft", "Escape"]]))
        for n in 1...7 {
            XCTAssertTrue(keys(.linux).contains([["ControlLeft", "AltLeft", "F\(n)"]]), "tty\(n)")
        }
        let reisub = KeyComboLibrary.groups(for: .linux).flatMap(\.items).first { $0.name.contains("REISUB") }
        XCTAssertEqual(try reisub?.steps().count, 6)
        XCTAssertEqual(reisub?.stepDelay, KeyComboLibrary.sysRqStepDelay)
    }

    func testCopyHasNewIdentity() {
        let item = KeyComboItem(name: "Lock", keys: "win+l", os: .windows, stepDelay: 1)
        let copy = item.copy()
        XCTAssertNotEqual(copy.id, item.id)
        XCTAssertEqual(copy.name, item.name)
        XCTAssertEqual(copy.keys, item.keys)
        XCTAssertEqual(copy.os, item.os)
        XCTAssertEqual(copy.stepDelay, item.stepDelay)
    }

    func testStorageRoundTrip() throws {
        let suite = "KeyComboItemTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(KeyComboStorage.load(from: defaults), [])
        let items = [
            KeyComboItem(name: "BIOS", keys: "f2"),
            KeyComboItem(name: "Reboot", keys: "alt+sysrq+s, alt+sysrq+b", os: .linux, stepDelay: 2),
        ]
        KeyComboStorage.save(items, to: defaults)
        XCTAssertEqual(KeyComboStorage.load(from: defaults), items)
    }

    func testDecodingFillsMissingFields() throws {
        let json = #"[{"keys":"f12","os":"beos"}]"#
        let items = try JSONDecoder().decode([KeyComboItem].self, from: Data(json.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].keys, "f12")
        XCTAssertEqual(items[0].name, "")
        XCTAssertNil(items[0].os)
        XCTAssertEqual(items[0].stepDelay, KeyComboItem.defaultStepDelay)
    }
}
