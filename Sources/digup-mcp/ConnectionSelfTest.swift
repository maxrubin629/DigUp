import Foundation
import Darwin
import DigUpKit

/// Uses the same stdio handshake and tools a real client uses, without a search or model load.
enum ConnectionSelfTest {
    static func run(executable: URL) -> MCPDiagnostics.TestReport {
        do { return try probe(executable: executable) }
        catch { return .init(success: false, message: error.localizedDescription) }
    }

    private static func probe(executable: URL) throws -> MCPDiagnostics.TestReport {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var pending = Data()
        func send(_ object: [String: Any]) throws {
            var message = try JSONSerialization.data(withJSONObject: object)
            message.append(10)
            try input.fileHandleForWriting.write(contentsOf: message)
        }
        func request(_ id: Int, _ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let end = pending.firstIndex(of: 10) {
                    let line = pending[..<end]
                    pending.removeSubrange(...end)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                        throw SearchFailure("The MCP server returned an invalid response.")
                    }
                    guard object["id"] as? Int == id else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw SearchFailure(error["message"] as? String ?? "The MCP request failed.")
                    }
                    guard let result = object["result"] as? [String: Any] else {
                        throw SearchFailure("The MCP response did not include a result.")
                    }
                    return result
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0, errno != EINTR { throw SearchFailure("Could not read the MCP server response.") }
                guard ready > 0 else { continue }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw SearchFailure("The MCP server stopped before the check finished. Reopen DigUp Personal and try again.") }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 1_048_576 else { throw SearchFailure("The MCP server returned an oversized response.") }
            }
            throw SearchFailure("The MCP server did not respond within 12 seconds. Reopen DigUp Personal and try again.")
        }
        let initialized = try request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:],
                                                        "clientInfo": ["name": "digup-personal-settings", "version": "1"]])
        guard initialized["protocolVersion"] as? String != nil else { throw SearchFailure("The MCP handshake was incomplete.") }
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let discovery = try request(2, "tools/list", [:])
        let tools = discovery["tools"] as? [[String: Any]] ?? []
        let names = Set(tools.compactMap { $0["name"] as? String })
        guard names == ["digup_search_files", "digup_get_result_context", "digup_index_status"] else {
            throw SearchFailure("The MCP server did not expose all three DigUp tools. Reinstall DigUp Personal.")
        }
        let status = try request(3, "tools/call", ["name": "digup_index_status", "arguments": [:]])
        if status["isError"] as? Bool == true {
            let content = status["content"] as? [[String: Any]]
            throw SearchFailure("The server connected, but the index could not be read. " +
                                (content?.first?["text"] as? String ?? "") +
                                " Check the index location in Storage settings.")
        }
        guard let values = status["structuredContent"] as? [String: Any], values["read_only"] as? Bool == true,
              let indexed = values["indexed"] as? Int else {
            throw SearchFailure("The server connected, but returned an incomplete index status.")
        }
        return .init(success: true, message: "Handshake, all three tools, and read-only index access passed.",
                     toolCount: tools.count, indexed: indexed, pending: values["pending"] as? Int,
                     modelReady: values["model_ready"] as? Bool)
    }
}
