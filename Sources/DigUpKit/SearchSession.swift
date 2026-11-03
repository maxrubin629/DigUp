import Foundation

public struct SearchPage: Sendable {
    public let hits: [SearchHit]
    public let hasMore: Bool
    public let nextOffset: Int?
    public let semantic: Bool
    public let warning: String?
}

/// Common ranking and scope enforcement. Attachments use vectors only; text retains hybrid retrieval.
public enum SearchExecution {
    public static func search(_ searcher: Searcher, text: String, vector: EncodedQuery?,
                              configuration: PersonalConfiguration, code: Bool = false,
                              media: Bool = false, kinds: Set<FileKind>? = nil,
                              limit: Int = 20, offset: Int = 0, prefixLast: Bool = false) throws -> SearchPage {
        guard limit > 0, limit <= 1000, offset >= 0, offset <= 100_000 else {
            throw SearchFailure("Use a positive result limit and a nonnegative offset.")
        }
        var vector = vector
        var warning: String?
        if let encoded = vector, let indexed = searcher.vectorSource, indexed != encoded.source {
            warning = "The query model does not match this index. Your index was left unchanged."
            if media { throw SearchFailure(warning!) }
            vector = nil
        }
        if media && vector == nil { throw SearchFailure("The attachment could not be encoded.") }
        let found = try searcher.search(text, queryVector: vector?.values, kinds: kinds,
                                       limit: offset + limit + 1, prefixLast: prefixLast,
                                       acceptsPath: configuration.pathFilter(code: code))
        let page = Array(found.dropFirst(offset).prefix(limit))
        let more = found.count > offset + limit
        return SearchPage(hits: page, hasMore: more, nextOffset: more ? offset + page.count : nil,
                          semantic: vector != nil, warning: warning)
    }
}

public struct ResultContext: Sendable {
    public let fields: [String: String]
    public let text: String?
    public let preview: Data?
}

/// One connection per index, always opened read-only. The owner serializes calls (MCP uses an actor).
public final class ReadOnlySearchSession {
    public private(set) var configuration: PersonalConfiguration
    private let helper: URL
    private var encoder: SearchQueryEncoder
    private var stores: [Bool: IndexStore] = [:]
    private var searchers: [Bool: Searcher] = [:]
    private var versions: [Bool: Int64] = [:]

    public init(configuration: PersonalConfiguration, helper: URL) {
        self.configuration = configuration
        self.helper = helper
        encoder = SearchQueryEncoder(helper: helper, models: configuration.modelsDirectory, idleSeconds: 600)
    }

    public func configure(_ new: PersonalConfiguration) {
        if new.indexDirectory != configuration.indexDirectory {
            stores = [:]; searchers = [:]; versions = [:]
        }
        if new.modelsDirectory != configuration.modelsDirectory {
            encoder.close()
            encoder = SearchQueryEncoder(helper: helper, models: new.modelsDirectory)
        }
        configuration = new
    }

    public func close() { encoder.close(); stores = [:]; searchers = [:]; versions = [:] }

    private func open(code: Bool) throws -> (IndexStore, Searcher) {
        if stores[code] == nil {
            let store = try IndexStore(directory: configuration.indexDirectory,
                                       file: code ? IndexStore.codeFile : IndexStore.mainFile, readOnly: true)
            stores[code] = store
            searchers[code] = try Searcher(store: store, loadVectors: false)
        }
        let store = stores[code]!, searcher = searchers[code]!
        var version: Int64 = 0
        try store.db.query("PRAGMA data_version") { version = $0.int(0) }
        if let previous = versions[code], version != previous { try searcher.reload() }
        versions[code] = version
        return (store, searcher)
    }

    public func search(_ input: SearchInput, kinds: Set<FileKind>? = nil, limit: Int = 20, offset: Int = 0) throws -> SearchPage {
        guard limit > 0, limit <= 100 else { throw SearchFailure("The result limit must be between 1 and 100.") }
        let text: String
        var code = false
        switch input {
        case .text(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SearchFailure("Enter search words or attach an image or audio clip.")
            }
            code = CodeQuery.text(of: value) != nil
            text = CodeQuery.text(of: value) ?? value
        default: text = ""
        }
        if code && configuration.codeRoots.isEmpty { throw SearchFailure("Code search is off. Choose code folders in DigUp Personal.") }
        if code && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SearchFailure("Add search words after code:.")
        }
        let (_, searcher) = try open(code: code)
        var vector: EncodedQuery?
        var encodeWarning: String?
        do { vector = try encoder.encode(input.isMedia ? input : .text(text), code: code) }
        catch {
            if input.isMedia { throw error }
            encodeWarning = "Semantic search is unavailable: \(error.localizedDescription). Showing keyword matches."
        }
        let page = try SearchExecution.search(searcher, text: text, vector: vector, configuration: configuration,
                                             code: code, media: input.isMedia, kinds: kinds, limit: limit, offset: offset)
        return SearchPage(hits: page.hits, hasMore: page.hasMore, nextOffset: page.nextOffset,
                          semantic: page.semantic, warning: page.warning ?? encodeWarning)
    }

    public func status() throws -> [String: String] {
        let (store, _) = try open(code: false)
        var counts: [String: Int] = [:]
        try store.db.query("SELECT state, COUNT(*) FROM files GROUP BY state") { counts[$0.text(0) ?? ""] = Int($0.int(1)) }
        return [
            "index": store.file.path,
            "indexed": String((counts["done"] ?? 0) + (counts["partial"] ?? 0)),
            "pending": String(counts["pending"] ?? 0),
            "failed": String(counts["failed"] ?? 0),
            "roots": configuration.roots.joined(separator: "\n"),
            "model_ready": String(ModelFiles.all.allSatisfy {
                FileManager.default.fileExists(atPath: configuration.modelsDirectory.appendingPathComponent($0.name).path)
            }),
            "vector_source": try store.meta("vector_source") ?? "",
            "read_only": "true",
        ]
    }

    public func context(_ id: String) throws -> ResultContext {
        let parts = id.split(separator: ":")
        guard parts.count == 2, ["files", "code"].contains(String(parts[0])),
              let segment = Int64(parts[1]), segment > 0 else { throw SearchFailure("Use a result_id returned by digup_search_files.") }
        let code = parts[0] == "code"
        let (store, searcher) = try open(code: code)
        var fields: [String: String] = [:]
        try store.db.query("""
            SELECT f.path, f.kind, s.kind, s.loc, s.loc_end FROM segments s
            JOIN files f ON f.id = s.file WHERE s.id = ?
            """, [.int(segment)]) { row in
            fields = ["path": row.text(0) ?? "", "kind": row.text(1) ?? "", "segment": row.text(2) ?? ""]
            if !row.isNull(3) { fields["loc"] = String(row.double(3)) }
            if !row.isNull(4) { fields["loc_end"] = String(row.double(4)) }
        }
        guard let path = fields["path"], configuration.allows(path, code: code) else {
            throw SearchFailure("This result is unavailable or is outside your chosen folders. Search again.")
        }
        let text = try searcher.text(ofSegment: segment).map { String($0.prefix(12_000)) }
        var preview: Data?
        #if os(macOS)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPreview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("preview.jpg")
        let url = URL(fileURLWithPath: path)
        do {
            switch fields["kind"] {
            case "image", "screenshot":
                let prepared = try ImageExtractor.prepare(url, maxPixel: 1024, minSide: 1, to: folder, png: false)
                preview = try Data(contentsOf: URL(fileURLWithPath: prepared.path))
            case "pdf":
                try PDFExtractor.renderPage(Int(Double(fields["loc"] ?? "") ?? 1), of: url, pixels: 1024, to: out)
                preview = try Data(contentsOf: out)
            case "video":
                let time = Double(fields["loc"] ?? "") ?? 0
                try runBlocking { try await VideoExtractor.frame(at: time, of: url, pixels: 1024, to: out) }
                preview = try Data(contentsOf: out)
            default: break
            }
        } catch { fields["preview_warning"] = error.localizedDescription }
        #endif
        return ResultContext(fields: fields, text: text, preview: preview)
    }

    public static func fields(_ hit: SearchHit, code: Bool = false) -> [String: Any] {
        var row: [String: Any] = [
            "result_id": "\(code ? "code" : "files"):\(hit.segmentID)", "path": hit.path,
            "kind": hit.kind.rawValue, "segment": hit.segment.rawValue, "score": hit.score,
            "modified": hit.modified, "size": hit.size,
        ]
        if let excerpt = hit.excerpt { row["excerpt"] = excerpt }
        if let loc = hit.loc { row["loc"] = loc }
        if let end = hit.locEnd { row["loc_end"] = end }
        if let focus = hit.focus { row["focus"] = focus }
        return row
    }
}
