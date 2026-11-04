import Foundation
import DigUpKit
import MCP

private func jsonValue(_ object: [String: Any]) throws -> Value {
    try JSONDecoder().decode(Value.self, from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

private func textBlock(_ text: String) -> Tool.Content { .text(text: text, annotations: nil, _meta: nil) }

private actor SearchHost {
    private var session: ReadOnlySearchSession?
    private let helper: URL
    init(helper: URL) { self.helper = helper }

    private func current() throws -> ReadOnlySearchSession {
        let configuration = try PersonalConfiguration.load()
        if let session { session.configure(configuration); return session }
        let value = ReadOnlySearchSession(configuration: configuration, helper: helper)
        session = value
        return value
    }

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let arguments = params.arguments ?? [:]
            let payload: [String: Any]
            var preview: Data?
            switch params.name {
            case "digup_search_files":
                let allowed: Set<String> = ["text", "image_path", "audio_path", "start_seconds", "duration_seconds", "kinds", "limit", "offset"]
                guard Set(arguments.keys).isSubset(of: allowed) else { throw SearchFailure("Unknown search argument.") }
                let input = try await input(arguments)
                let limit = try integer(arguments, "limit", default: 20, range: 1...100)
                let offset = try integer(arguments, "offset", default: 0, range: 0...100_000)
                var kinds: Set<FileKind>?
                if let values = arguments["kinds"] {
                    guard let values = values.arrayValue, !values.isEmpty else { throw SearchFailure("kinds must be a nonempty array of file types.") }
                    var result = Set<FileKind>()
                    for item in values {
                        guard let name = item.stringValue, let kind = FileKind(rawValue: name), kind != .code else {
                            throw SearchFailure("Use screenshot, image, pdf, doc, audio, or video in kinds. Use a text query starting with code: for source code.")
                        }
                        result.insert(kind)
                    }
                    kinds = result
                }
                let page = try current().search(input, kinds: kinds, limit: limit, offset: offset)
                let code: Bool
                if case .text(let text) = input { code = CodeQuery.text(of: text) != nil } else { code = false }
                payload = [
                    "results": page.hits.map { ReadOnlySearchSession.fields($0, code: code) },
                    "has_more": page.hasMore, "next_offset": page.nextOffset.map { $0 as Any } ?? NSNull(),
                    "semantic": page.semantic, "warning": page.warning.map { $0 as Any } ?? NSNull(),
                ]
            case "digup_get_result_context":
                guard Set(arguments.keys) == ["result_id"], let id = arguments["result_id"]?.stringValue else {
                    throw SearchFailure("Provide result_id from digup_search_files.")
                }
                let result = try current().context(id)
                payload = ["result": result.fields, "text": result.text.map { $0 as Any } ?? NSNull()]
                preview = result.preview
            case "digup_index_status":
                guard arguments.isEmpty else { throw SearchFailure("digup_index_status takes no arguments.") }
                let value = try current()
                let status = try value.status()
                payload = [
                    "index": status["index"] ?? "", "indexed": Int(status["indexed"] ?? "") ?? 0,
                    "pending": Int(status["pending"] ?? "") ?? 0, "failed": Int(status["failed"] ?? "") ?? 0,
                    "roots": value.configuration.roots, "model_ready": status["model_ready"] == "true",
                    "vector_source": status["vector_source"] ?? "", "read_only": true,
                ]
            default: throw SearchFailure("Unknown tool: \(params.name)")
            }
            try Task.checkCancellation()
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            var content = [textBlock(String(decoding: data, as: UTF8.self))]
            if let preview { content.append(.image(data: preview.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)) }
            return try CallTool.Result(content: content, structuredContent: try jsonValue(payload), isError: false)
        } catch {
            return CallTool.Result(content: [textBlock(error.localizedDescription)], isError: true)
        }
    }

    private func integer(_ args: [String: Value], _ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let item = args[key] else { return fallback }
        guard let value = item.intValue, range.contains(value) else { throw SearchFailure("\(key) must be an integer in \(range).") }
        return value
    }

    private func input(_ args: [String: Value]) async throws -> SearchInput {
        let keys = ["text", "image_path", "audio_path"].filter { args[$0] != nil }
        guard keys.count == 1, let key = keys.first, let value = args[key]?.stringValue, !value.isEmpty else {
            throw SearchFailure("Provide exactly one of text, image_path, or audio_path.")
        }
        if key != "audio_path", args["start_seconds"] != nil || args["duration_seconds"] != nil {
            throw SearchFailure("Clip times apply only to audio_path.")
        }
        if key == "text" { return .text(value) }
        guard value.hasPrefix("/") else { throw SearchFailure("Use an absolute local path for the query attachment.") }
        let url = URL(fileURLWithPath: value)
        if key == "image_path" { return .image(url) }
        let total = try await SearchInput.audioDuration(of: url)
        if total > 30, args["start_seconds"] == nil || args["duration_seconds"] == nil {
            throw SearchFailure("This recording is \(Int(total)) seconds long. Choose a clip with start_seconds and duration_seconds (at most 30).")
        }
        func number(_ key: String, fallback: Double) throws -> Double {
            guard let value = args[key] else { return fallback }
            if let number = value.doubleValue { return number }
            if let number = value.intValue { return Double(number) }
            throw SearchFailure("\(key) must be a number.")
        }
        let start = try number("start_seconds", fallback: 0)
        let duration = try number("duration_seconds", fallback: min(30, total - start))
        guard start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 30,
              start < total, start + duration <= total + 0.02 else {
            throw SearchFailure("Choose a valid audio range of at most 30 seconds within the recording.")
        }
        return .audio(url, start: start, duration: duration)
    }
}

@main
private struct DigUpMCP {
    static func main() async throws {
        signal(SIGPIPE, SIG_IGN)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if CommandLine.arguments.dropFirst().contains("--self-test") {
            let report = ConnectionSelfTest.run(executable: executable)
            var data = try JSONEncoder().encode(report)
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
            exit(report.success ? 0 : 1)
        }
        let helper = ProcessInfo.processInfo.environment["DIGUP_HELPER"].map { URL(fileURLWithPath: $0) }
            ?? executable.deletingLastPathComponent().appendingPathComponent("digup")
        let host = SearchHost(helper: helper)
        let server = Server(name: "digup-personal", version: "0.1.0", title: "DigUp Personal",
            instructions: "Search the user's existing local DigUp index. Use exactly one text query, image path, or audio clip per search. Results obey chosen folders and exclusions. This server never indexes or edits files. Use digup_get_result_context for a returned result_id. Audio examples search by content; they are not transcribed. Recordings over 30 seconds require an explicit clip. Use code: in text to search configured code folders.",
            capabilities: .init(tools: .init(listChanged: false)))
        let annotations = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        let objectOutput: Value = .object(["type": .string("object"), "additionalProperties": .bool(true)])
        let searchSchema = try jsonValue([
            "type": "object", "additionalProperties": false,
            "properties": [
                "text": ["type": "string", "minLength": 1, "description": "Search words; start with code: to search source code."],
                "image_path": ["type": "string", "minLength": 1, "description": "Absolute local path of an image example."],
                "audio_path": ["type": "string", "minLength": 1, "description": "Absolute local path of an audio example."],
                "start_seconds": ["type": "number", "minimum": 0],
                "duration_seconds": ["type": "number", "exclusiveMinimum": 0, "maximum": 30],
                "kinds": ["type": "array", "minItems": 1, "items": ["type": "string", "enum": ["screenshot", "image", "pdf", "doc", "audio", "video"]]],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "default": 20],
                "offset": ["type": "integer", "minimum": 0, "maximum": 100000, "default": 0],
            ],
            "oneOf": [
                ["required": ["text"], "not": ["anyOf": [["required": ["image_path"]], ["required": ["audio_path"]]]]],
                ["required": ["image_path"], "not": ["anyOf": [["required": ["text"]], ["required": ["audio_path"]]]]],
                ["required": ["audio_path"], "not": ["anyOf": [["required": ["text"]], ["required": ["image_path"]]]]],
            ],
        ])
        let tools = [
            Tool(name: "digup_search_files", title: "Search files", description: "Search indexed files by text, an image example, or an audio example. Returns paths, excerpts and matching pages/times. Queries do not add files to the index.", inputSchema: searchSchema, annotations: annotations, outputSchema: objectOutput),
            Tool(name: "digup_get_result_context", title: "Read search result", description: "Get the indexed passage and available image/PDF-page/video-frame preview for a search result. Audio results retain their time range; no transcription is generated.", inputSchema: try jsonValue(["type": "object", "properties": ["result_id": ["type": "string"]], "required": ["result_id"], "additionalProperties": false]), annotations: annotations, outputSchema: objectOutput),
            Tool(name: "digup_index_status", title: "Index status", description: "Read index counts, chosen folders and model readiness. Does not start indexing or load the model.", inputSchema: .object(["type": .string("object"), "additionalProperties": .bool(false)]), annotations: annotations, outputSchema: objectOutput),
        ]
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in await host.call(params) }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
