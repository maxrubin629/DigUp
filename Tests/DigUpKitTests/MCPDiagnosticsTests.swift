import Foundation
import Testing
@testable import DigUpKit

#if os(macOS)
@Suite struct MCPDiagnosticsTests {
    let helper = URL(fileURLWithPath: "/Applications/DigUp Personal.app/Contents/Helpers/digup-mcp")

    private func configuration(command: String, enabled: Bool = true, type: String = "stdio", args: [String] = []) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["enabled": enabled,
            "transport": ["type": type, "command": command, "args": args]])
    }

    @Test func distinguishesEnabledDisabledAndDifferentCommands() throws {
        let ready = try MCPDiagnostics.configuration(from: configuration(command: helper.path), expectedHelper: helper)
        #expect(ready.state == .ready)
        let disabled = try MCPDiagnostics.configuration(from: configuration(command: helper.path, enabled: false), expectedHelper: helper)
        #expect(disabled.state == .disabled)
        let other = try MCPDiagnostics.configuration(from: configuration(command: "/tmp/another-server"), expectedHelper: helper)
        #expect(other.state == .different)
        let relative = try MCPDiagnostics.configuration(from: configuration(command: "digup-mcp"), expectedHelper: helper)
        #expect(relative.state == .different)
        let arguments = try MCPDiagnostics.configuration(from: configuration(command: helper.path, args: ["--some-other-mode"]), expectedHelper: helper)
        #expect(arguments.state == .different)
        let remote = try MCPDiagnostics.configuration(from: configuration(command: helper.path, type: "http"), expectedHelper: helper)
        #expect(remote.state == .different)
    }

    @Test func malformedConfigurationCannotClaimConnected() throws {
        #expect(throws: (any Error).self) {
            try MCPDiagnostics.configuration(from: Data("{}".utf8), expectedHelper: helper)
        }
        #expect(throws: (any Error).self) {
            try MCPDiagnostics.configuration(from: Data("not json".utf8), expectedHelper: helper)
        }
    }

    @Test func processCaptureSeparatesLogsAndPreservesFailureExit() throws {
        let result = try DiagnosticProcess.run(executable: URL(fileURLWithPath: "/bin/sh"),
                                              arguments: ["-c", "printf 'result'; printf 'log' >&2; exit 7"], timeout: 2)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "result")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "log")
        #expect(result.status == 7)
    }

    @Test func unresponsiveProcessHasABoundedTimeout() throws {
        let started = ProcessInfo.processInfo.systemUptime
        #expect(throws: SearchFailure.self) {
            try DiagnosticProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - started < 3)
    }

    @Test func missingBundledServerReturnsAnActionableFailure() {
        let result = MCPDiagnostics.testLocalServer(helper: URL(fileURLWithPath: "/missing/digup-mcp"))
        #expect(!result.success)
        #expect(result.message.contains("Reinstall"))
    }
}
#endif
