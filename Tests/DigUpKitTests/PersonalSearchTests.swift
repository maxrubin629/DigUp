import Foundation
import Testing
@testable import DigUpKit

@Suite final class PersonalSearchTests: Sendable {
    let folder: URL
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpPersonalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: folder) }

    private func store() throws -> IndexStore {
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        try store.setMeta("vector_source", PersonalConfiguration.vectorSource)
        try store.setMeta("fingerprint", "\(PersonalConfiguration.vectorSource) | \(IndexOptions().fingerprint)")
        return store
    }

    @discardableResult private func add(_ name: String, to store: IndexStore, text: String = "needle",
                                        vector: [Float]? = nil) throws -> Int64 {
        let path = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
        let id = try store.insert(Candidate(path: path.path, kind: .doc, size: Int64(text.utf8.count),
                                           mtime: 1, inode: UInt64(abs(name.hashValue % 100000) + 1), device: 1))
        try store.addSegment(file: id, kind: .chunk, modality: .text, text: text, vector: vector)
        try store.finish(id, state: "done")
        return id
    }

    @Test func readOnlyConnectionsCannotWriteOrCreateAnIndex() throws {
        let writer = try store()
        try add("chosen/needle.txt", to: writer)
        let reader = try IndexStore(directory: writer.directory, readOnly: true)
        #expect(throws: Database.Failure.self) { try reader.setMeta("vector_source", "changed") }
        #expect(try reader.meta("vector_source") == PersonalConfiguration.vectorSource)
        let missing = folder.appendingPathComponent("missing")
        #expect(throws: Database.Failure.self) { try IndexStore(directory: missing, readOnly: true) }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func adoptionBacksUpCommittedWALWithoutChangingVectors() throws {
        let writer = try store()
        let vector = FakeEmbedder.vector(for: "existing")
        try add("chosen/one.txt", to: writer, vector: vector)
        let originalFingerprint = try writer.meta("fingerprint")
        var original: Data?
        try writer.db.query("SELECT vec FROM segments WHERE vec IS NOT NULL LIMIT 1") { original = $0.blob(0) }
        try IndexAdoption.prepareForWriting(directory: writer.directory)
        let saved = try IndexStore(directory: writer.directory.appendingPathComponent("backups/before-personal"), readOnly: true)
        #expect(try saved.files(under: [folder.path]).count == 1)
        var copied: Data?
        try saved.db.query("SELECT vec FROM segments WHERE vec IS NOT NULL LIMIT 1") { copied = $0.blob(0) }
        #expect(copied == original)
        #expect(try saved.meta("fingerprint") == originalFingerprint)
        #expect(try writer.meta("fingerprint") == originalFingerprint)
        try add("chosen/two.txt", to: writer)
        try IndexAdoption.prepareForWriting(directory: writer.directory)
        #expect(try saved.files(under: [folder.path]).count == 1)
        #expect(try writer.files(under: [folder.path]).count == 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_ADOPTION_TEST_INDEX"] != nil))
    func adoptsDisposableExistingIndexWithoutReembedding() throws {
        let path = try #require(ProcessInfo.processInfo.environment["DIGUP_ADOPTION_TEST_INDEX"])
        let directory = URL(fileURLWithPath: path)
        #expect(directory.standardizedFileURL != AppPaths.defaultIndex.standardizedFileURL)
        guard directory.standardizedFileURL != AppPaths.defaultIndex.standardizedFileURL else { return }
        let source = try IndexStore(directory: directory, readOnly: true)
        let fingerprint = try source.meta("fingerprint")
        let before = try source.counts()
        var sample: [Data] = []
        try source.db.query("SELECT vec FROM segments WHERE vec IS NOT NULL ORDER BY id LIMIT 5") {
            if let data = $0.blob(0) { sample.append(data) }
        }
        try IndexAdoption.prepareForWriting(directory: directory)
        let backup = try IndexStore(directory: directory.appendingPathComponent("backups/before-personal"), readOnly: true)
        #expect(try backup.meta("fingerprint") == fingerprint)
        #expect(try source.meta("fingerprint") == fingerprint)
        #expect(try source.counts().byKindAndState == before.byKindAndState)
        #expect(try backup.counts().vectors == before.vectors)
        var after: [Data] = []
        try backup.db.query("SELECT vec FROM segments WHERE vec IS NOT NULL ORDER BY id LIMIT 5") {
            if let data = $0.blob(0) { after.append(data) }
        }
        #expect(after == sample)
    }

    @Test func incompatibleModelAndSchemaAreNeverReset() throws {
        let writer = try store()
        try add("chosen/original.txt", to: writer)
        try writer.setMeta("vector_source", "different")
        #expect(throws: SearchFailure.self) { try IndexAdoption.prepareForWriting(directory: writer.directory) }
        #expect(try writer.files(under: [folder.path]).count == 1)
        try writer.setMeta("vector_source", PersonalConfiguration.vectorSource)
        try writer.db.execute("PRAGMA user_version = 6")
        #expect(throws: Database.Failure.self) { try IndexAdoption.check(directory: writer.directory) }
        var version: Int64 = 0
        try writer.db.query("PRAGMA user_version") { version = $0.int(0) }
        #expect(version == 6)
        #expect(!FileManager.default.fileExists(atPath: writer.directory.appendingPathComponent("backups").path))
    }

    @Test func folderScopeHonorsFilesystemAliases() throws {
        let writer = try store()
        try add("chosen/needle.txt", to: writer)
        let path = folder.appendingPathComponent("chosen/needle.txt").path
        let canonical = FolderSelection.realPath(path)
        let config = PersonalConfiguration(indexDirectory: writer.directory, roots: [folder.path])
        #expect(config.allows(path))
        #expect(config.allows(canonical))
        var excluded = config
        excluded.excluded = [FolderSelection.realPath(folder.appendingPathComponent("chosen").path)]
        #expect(!excluded.allows(path))
    }

    @Test func scopeAndExclusionsApplyBeforePagination() throws {
        let writer = try store()
        for i in 0..<110 { try add("excluded/needle\(i).txt", to: writer) }
        for i in 0..<4 { try add("chosen/needle\(i).txt", to: writer) }
        let config = PersonalConfiguration(indexDirectory: writer.directory, roots: [folder.path],
                                           excluded: [folder.appendingPathComponent("excluded").path])
        let searcher = try Searcher(store: IndexStore(directory: writer.directory, readOnly: true), loadVectors: false)
        let first = try SearchExecution.search(searcher, text: "needle", vector: nil, configuration: config, limit: 2)
        let second = try SearchExecution.search(searcher, text: "needle", vector: nil, configuration: config, limit: 2, offset: 2)
        #expect(first.hits.count == 2)
        #expect(first.hasMore && first.nextOffset == 2)
        #expect(second.hits.count == 2 && !second.hasMore)
        #expect(Set(first.hits.map(\.path)).isDisjoint(with: Set(second.hits.map(\.path))))
        #expect((first.hits + second.hits).allSatisfy { $0.path.contains("/chosen/") })
    }

    @Test func persistentSearchRefreshesAfterExternalWritesAndRechecksScope() throws {
        let writer = try store()
        try add("chosen/needle.txt", to: writer)
        var config = PersonalConfiguration(indexDirectory: writer.directory, modelsDirectory: folder,
                                            roots: [folder.appendingPathComponent("chosen").path])
        let session = ReadOnlySearchSession(configuration: config, helper: folder.appendingPathComponent("missing-helper"))
        let first = try session.search(.text("needle"))
        #expect(first.hits.count == 1 && !first.semantic && first.warning != nil)
        let id = "files:\(first.hits[0].segmentID)"
        #expect(try session.context(id).text == "needle")
        try add("chosen/second.txt", to: writer)
        #expect(try session.search(.text("needle")).hits.count == 2)
        config.roots = [folder.path]
        config.excluded = [folder.appendingPathComponent("chosen").path]
        session.configure(config)
        #expect(try session.search(.text("needle")).hits.isEmpty)
        #expect(throws: SearchFailure.self) { try session.context(id) }
        #expect(throws: SearchFailure.self) { try session.context("files:../../secret") }
        session.close()
    }

    @Test func mediaRequiresMatchingVectorSource() throws {
        let writer = try store()
        let searcher = try Searcher(store: writer, loadVectors: false)
        let config = PersonalConfiguration(indexDirectory: writer.directory)
        let encoded = EncodedQuery(values: FakeEmbedder.vector(for: "image"), source: "different")
        #expect(throws: SearchFailure.self) {
            try SearchExecution.search(searcher, text: "", vector: encoded, configuration: config, media: true)
        }
    }

    #if os(macOS)
    @Test func audioSelectionValidatesSilenceAndReadsOnlyTheChosenRange() async throws {
        let source = folder.appendingPathComponent("recording.wav")
        let samples = (0..<40 * 16000).map { index -> Int16 in
            index < 31 * 16000 ? 0 : Int16(5000 * sin(Double(index) * 0.1))
        }
        try AudioExtractor.writeWAV(samples[...], to: source)
        #expect(throws: SearchFailure.self) {
            try runBlocking { try await AudioExtractor.queryClip(of: source, start: 0, duration: 30, to: self.folder) }
        }
        let clip = try await AudioExtractor.queryClip(of: source, start: 32, duration: 3, to: folder)
        let duration = try await SearchInput.audioDuration(of: clip)
        #expect(abs(duration - 3) < 0.02)
        await #expect(throws: SearchFailure.self) {
            try await AudioExtractor.queryClip(of: source, start: 0, duration: 31, to: self.folder)
        }
        await #expect(throws: SearchFailure.self) {
            try await AudioExtractor.queryClip(of: source, start: 39, duration: 2, to: self.folder)
        }
    }
    #endif
}
