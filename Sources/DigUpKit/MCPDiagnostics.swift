import Foundation
#if os(macOS)
import Darwin

/// Diagnostics never run the executable named in Codex's configuration.
public enum MCPDiagnostics {
    public struct Configuration: Sendable, Equatable {
        public enum State: Sendable { case ready, missing, disabled, different, unavailable }
        public let state: State
        public let title: String
        public let detail: String
    }

    public struct TestReport: Codable, Sendable {
        public let success: Bool
        public let message: String
        public let toolCount: Int?
        public let indexed: Int?
        public let pending: Int?
        public let modelReady: Bool?

        public init(success: Bool, message: String, toolCount: Int? = nil, indexed: Int? = nil,
                    pending: Int? = nil, modelReady: Bool? = nil) {
            self.success = success; self.message = message; self.toolCount = toolCount
            self.indexed = indexed; self.pending = pending; self.modelReady = modelReady
        }
    }

    public static func configuration(from data: Data, expectedHelper: URL) throws -> Configuration {
        struct Saved: Decodable {
            struct Transport: Decodable { let type: String; let command: String?; let args: [String]? }
            let enabled: Bool
            let transport: Transport
        }
        let saved = try JSONDecoder().decode(Saved.self, from: data)
        guard saved.enabled != false else {
            return Configuration(state: .disabled, title: "Disabled in Codex", detail: "Enable the digup connection in Codex, then restart Codex.")
        }
        guard saved.transport.type == "stdio", let command = saved.transport.command,
              command.hasPrefix("/"), URL(fileURLWithPath: command).resolvingSymlinksInPath().standardizedFileURL
                == expectedHelper.resolvingSymlinksInPath().standardizedFileURL,
              saved.transport.args?.isEmpty != false else {
            return Configuration(state: .different, title: "Different server configured",
                                 detail: "Codex's digup entry points to a different command or app copy. Use the command below to connect this app.")
        }
        return Configuration(state: .ready, title: "Configured in Codex",
                             detail: "The digup entry is enabled and points to this app. Restart Codex after changing its configuration.")
    }

    public static func checkConfiguration(expectedHelper: URL) -> Configuration {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/codex").path,
                          home.appendingPathComponent(".codex/packages/standalone/current/bin/codex").path,
                          "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        guard let command = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return Configuration(state: .unavailable, title: "Codex CLI not found",
                                 detail: "Install the Codex CLI to check its configuration. You can still test DigUp's local server below.")
        }
        do {
            let output = try DiagnosticProcess.run(executable: URL(fileURLWithPath: command),
                                                   arguments: ["mcp", "get", "digup", "--json"], timeout: 8)
            if output.status == 0 { return try configuration(from: output.stdout, expectedHelper: expectedHelper) }
            let message = String(decoding: output.stderr, as: UTF8.self)
            if message.localizedCaseInsensitiveContains("No MCP server named") {
                return Configuration(state: .missing, title: "Not configured in Codex", detail: "Copy and run the connection command below, then restart Codex.")
            }
            return Configuration(state: .unavailable, title: "Could not check Codex",
                                 detail: "Run codex mcp get digup --json in Terminal to inspect the configuration, then try Refresh.")
        } catch let error as SearchFailure {
            return Configuration(state: .unavailable, title: "Could not check Codex", detail: error.localizedDescription)
        } catch {
            return Configuration(state: .unavailable, title: "Could not check Codex",
                                 detail: "Codex's configuration could not be read. Run codex mcp get digup --json in Terminal, then try Refresh.")
        }
    }

    public static func testLocalServer(helper: URL) -> TestReport {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            return TestReport(success: false, message: "The bundled MCP server is missing. Reinstall DigUp Personal and try again.")
        }
        do {
            let result = try DiagnosticProcess.run(executable: helper, arguments: ["--self-test"], timeout: 20)
            let report = try JSONDecoder().decode(TestReport.self, from: result.stdout)
            guard result.status == 0 || !report.success else {
                return TestReport(success: false, message: "The server exited unexpectedly. Reopen DigUp Personal and try again.")
            }
            return report
        } catch {
            return TestReport(success: false, message: "Local server test failed: \(error.localizedDescription)")
        }
    }
}

/// A bounded process capture, shared by settings diagnostics and their tests.
public enum DiagnosticProcess {
    public struct Output: Sendable { public let status: Int32; public let stdout: Data; public let stderr: Data }

    public static func run(executable: URL, arguments: [String], timeout: TimeInterval) throws -> Output {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        // Resolve relative config paths consistently, regardless of how Finder launched the app.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
        }
        var streams = [pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: errors.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)]
        var data = [Data(), Data()]
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while streams.contains(where: { $0.fd >= 0 }) || process.isRunning {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw SearchFailure("The check timed out. Close and reopen Codex or DigUp Personal, then try again.")
            }
            let count = poll(&streams, nfds_t(streams.count), 50)
            if count < 0, errno != EINTR { throw SearchFailure("Could not read the diagnostic process response.") }
            for index in streams.indices where streams[index].fd >= 0 && streams[index].revents != 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let size = read(streams[index].fd, &buffer, buffer.count)
                if size == 0 { streams[index].fd = -1 }
                else if size > 0 {
                    data[index].append(contentsOf: buffer.prefix(size))
                    guard data[index].count <= 1_048_576 else { throw SearchFailure("The diagnostic response was too large.") }
                } else if errno != EINTR { streams[index].fd = -1 }
            }
        }
        return Output(status: process.terminationStatus, stdout: data[0], stderr: data[1])
    }
}
#endif
