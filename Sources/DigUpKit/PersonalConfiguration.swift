import Foundation

/// The fork owns its preferences, while continuing to use the original index and weights.
public struct PersonalConfiguration: Codable, Sendable {
    public static let defaultsSuite = "dev.digup.personal"
    public static let originalSuite = "com.abdurrahim.DigUp"
    public static let vectorSource = "google/embeddinggemma-2@\(ModelFiles.revision.prefix(7)) llama.cpp-vectors1 text-q8_0+mmproj-q8_0"

    public var indexDirectory: URL
    public var modelsDirectory: URL
    public var roots: [String]
    public var excluded: [String]
    public var excludedTypes: Set<String>
    public var codeRoots: [String]
    public var codeExcluded: [String]

    public init(indexDirectory: URL = AppPaths.defaultIndex, modelsDirectory: URL = ModelFiles.installed,
                roots: [String] = [], excluded: [String] = [], excludedTypes: Set<String> = [],
                codeRoots: [String] = [], codeExcluded: [String] = []) {
        self.indexDirectory = indexDirectory
        self.modelsDirectory = modelsDirectory
        self.roots = roots
        self.excluded = excluded
        self.excludedTypes = excludedTypes
        self.codeRoots = codeRoots
        self.codeExcluded = codeExcluded
    }

    /// Explicit test configuration never reads or changes the user's preferences.
    public static func load() throws -> Self {
        if let path = ProcessInfo.processInfo.environment["DIGUP_SETTINGS_FILE"] {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        }
        #if os(macOS)
        // Synchronize the read cache so a long-running MCP sees settings saved by the app.
        for suite in [defaultsSuite, originalSuite] { CFPreferencesAppSynchronize(suite as CFString) }
        let personal = UserDefaults.standard.persistentDomain(forName: defaultsSuite) ?? [:]
        let saved = personal["personalImported"] as? Bool == true ? personal
            : UserDefaults.standard.persistentDomain(forName: originalSuite) ?? [:]
        func paths(_ key: String) -> [String] {
            let values = saved[key] as? [String]
                ?? (saved[key] as? String)?.split(separator: ":").map(String.init) ?? []
            return values.map { ($0 as NSString).expandingTildeInPath }
        }
        func location(_ key: String, _ fallback: URL) -> URL {
            (saved[key] as? String).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? fallback
        }
        let extensions = (saved["excludedTypes"] as? [String])?.joined(separator: ",")
            ?? (saved["excludedTypes"] as? String) ?? ""
        return Self(indexDirectory: location("indexDir", AppPaths.defaultIndex),
                    modelsDirectory: location("modelsDir", ModelFiles.installed), roots: paths("roots"),
                    excluded: paths("excludedFolders"),
                    excludedTypes: IndexOptions.extensions(extensions),
                    codeRoots: paths("codeRoots"), codeExcluded: paths("codeExcludedFolders"))
        #else
        return Self()
        #endif
    }

    public func pathFilter(code: Bool = false) -> (String) -> Bool {
        let folders = (code ? codeRoots : roots).map(FolderSelection.realPath)
        let skipped = (code ? codeExcluded : excluded).map(FolderSelection.realPath)
        let types = excludedTypes
        return { path in
            guard let info = FileSystem.info(of: path), info.isRegular, !info.dataless else { return false }
            return FolderSelection.isSearched(FolderSelection.realPath(path), folders: folders, skipped: skipped)
                && (code || !types.contains((path as NSString).pathExtension.lowercased()))
        }
    }

    public func allows(_ path: String, code: Bool = false) -> Bool { pathFilter(code: code)(path) }

    /// Imports all app preferences once, including schedules and onboarding, without altering the original domain.
    public static func importPreferences(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: "personalImported") else { return }
        let source = UserDefaults.standard.persistentDomain(forName: originalSuite) ?? [:]
        for (key, value) in source where !key.hasPrefix("SU") && !key.hasPrefix("NS") {
            if defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: "personalImported")
    }
}

public struct SearchFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum IndexAdoption {
    public static func check(directory: URL) throws {
        for name in [IndexStore.mainFile, IndexStore.codeFile] {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) else { continue }
            let store = try IndexStore(directory: directory, file: name, readOnly: true)
            if let source = try store.meta("vector_source"), source != PersonalConfiguration.vectorSource {
                throw SearchFailure("This index uses \(source). DigUp Personal requires \(PersonalConfiguration.vectorSource). The index was not changed.")
            }
            var options = IndexOptions()
            options.code = name == IndexStore.codeFile
            if let fingerprint = try store.meta("fingerprint"),
               fingerprint != "\(PersonalConfiguration.vectorSource) | \(options.fingerprint)" {
                throw SearchFailure("The existing index uses different indexing settings. It was left unchanged.")
            }
        }
    }

    /// Called on the indexing queue, before any connection can migrate, prune, or write.
    public static func prepareForWriting(directory: URL) throws {
        try check(directory: directory)
        let backup = directory.appendingPathComponent("backups/before-personal")
        for name in [IndexStore.mainFile, IndexStore.codeFile] {
            let source = directory.appendingPathComponent(name)
            let target = backup.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: target.path) else { continue }
            try Database(path: source.path, readOnly: true).backup(to: target)
        }
    }
}
