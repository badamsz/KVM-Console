import XCTest
@testable import PiKVMKit

final class DeviceUpdateTests: XCTestCase {
    func testTerminalTextStripsEscapesAndAppliesCarriageReturns() {
        var t = TerminalText()
        t.append("\u{1B}]0;PiKVM Terminal\u{07}\u{1B}[1;32mhello\u{1B}[0m\r\n")
        t.append("downloading  10%\rdownloading 100%\r\nab\u{08}c\n")
        XCTAssertEqual(t.lines, ["hello", "downloading 100%", "ac", ""])
    }

    func testTerminalTextHandlesEscapeSplitAcrossChunks() {
        var t = TerminalText()
        t.append("a\u{1B}[3")
        t.append("1mb\r")
        t.append("\nc")
        XCTAssertEqual(t.lines, ["ab", "c"])
    }

    private func started() -> DeviceUpdateRun {
        var run = DeviceUpdateRun()
        XCTAssertNil(run.receive("Password: not a prompt yet\r\n[kvmd-webterm@pikvm ~]$ ", rootPassword: "pw"))
        XCTAssertEqual(run.start(), DeviceUpdateRun.command)
        // The shell echoes the command back.
        XCTAssertNil(run.receive(DeviceUpdateRun.command.replacingOccurrences(of: "\n", with: "\r\n"), rootPassword: "pw"))
        XCTAssertEqual(run.phase, .waitingForPasswordPrompt)
        XCTAssertEqual(run.receive("Password: ", rootPassword: "pw"), "pw\n")
        XCTAssertEqual(run.phase, .running)
        return run
    }

    func testCommandEchoNeverMatchesMarkers() {
        XCTAssertNil(DeviceUpdateRun.exitCode(in: DeviceUpdateRun.command))
        XCTAssertFalse(DeviceUpdateRun.command.contains("PIKVM_UPDATE_SU_FAILED"))
    }

    func testUpToDate() {
        var run = started()
        _ = run.receive("\r\n+ rw\r\n+ pacman -Syy\r\n================================\r\nYour PiKVM is already up-to-date\r\n", rootPassword: "pw")
        XCTAssertEqual(run.phase, .running)
        _ = run.receive("+ ro\r\n+ exit 0\r\nPIKVM_UPDATE_EXIT=", rootPassword: "pw")
        XCTAssertEqual(run.phase, .running, "exit code line is not complete yet")
        _ = run.receive("0\r\n", rootPassword: "pw")
        XCTAssertEqual(run.phase, .finished(.upToDate))
    }

    func testRebooting() {
        var run = started()
        _ = run.receive("\r\n      Reboot required. We will make it after 30 seconds.\r\n", rootPassword: "pw")
        XCTAssertEqual(run.phase, .finished(.rebooting))
    }

    func testWrongRootPassword() {
        var run = started()
        _ = run.receive("\r\nsu: Authentication failure\r\nPIKVM_UPDATE_SU_FAILED\r\n", rootPassword: "pw")
        XCTAssertEqual(run.phase, .finished(.wrongRootPassword))
    }

    func testFailureExitCode() {
        var run = started()
        _ = run.receive("\r\n!!! DO NOT REBOOT !!!\r\nPIKVM_UPDATE_EXIT=101\r\n", rootPassword: "pw")
        XCTAssertEqual(run.phase, .finished(.failed(code: 101)))
    }

    func testPasswordIsSentOnlyOnce() {
        var run = started()
        XCTAssertNil(run.receive("Password: ", rootPassword: "pw"))
    }
}
