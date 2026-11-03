import Foundation
#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif

public enum SearchInput: Sendable, Equatable {
    case text(String)
    case image(URL)
    case audio(URL, start: Double, duration: Double)

    public var isMedia: Bool { if case .text = self { false } else { true } }
    public var file: URL? {
        switch self { case .text: nil; case .image(let url), .audio(let url, _, _): url }
    }
    public var label: String { file?.lastPathComponent ?? "" }

    public static func audioDuration(of url: URL) async throws -> Double {
        #if canImport(AVFoundation)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SearchFailure("This recording has no playable audio.") }
        return duration
        #else
        throw SearchFailure("Audio queries currently require macOS.")
        #endif
    }
}

public struct EncodedQuery: Sendable {
    public let values: [Float]
    public let source: String
    public init(values: [Float], source: String) { self.values = values; self.source = source }
}

/// A shared encoder used by the app and MCP. Calls are serialized; the heavy model is loaded only for media.
public final class SearchQueryEncoder: @unchecked Sendable {
    private let helper: URL
    private let models: URL
    private let logs: URL?
    private let idleSeconds: Double
    private let lock = NSLock()
    private var textWorker: EmbeddingWorker?
    private var mediaWorker: EmbeddingWorker?
    private var idle: DispatchWorkItem?

    public init(helper: URL, models: URL, logs: URL? = nil, idleSeconds: Double = 600) {
        self.helper = helper; self.models = models; self.logs = logs; self.idleSeconds = idleSeconds
    }

    deinit { textWorker?.close(); mediaWorker?.close(); idle?.cancel() }

    public func close() {
        lock.withLock {
            textWorker?.close(); mediaWorker?.close()
            textWorker = nil; mediaWorker = nil; idle?.cancel(); idle = nil
        }
    }

    public func encode(_ input: SearchInput, code: Bool = false) throws -> EncodedQuery {
        try lock.withLock {
            if code && input.isMedia { throw SearchFailure("Code search accepts text queries.") }
            defer { scheduleIdleExit() }
            do {
                if case .text(let text) = input {
                    let worker = try runningWorker(media: false)
                    let vector = try worker.embedTexts([code ? Prompts.codeQuery(text) : Prompts.query(text)]).first ?? []
                    return try checked(vector, source: worker.info.vectorSource)
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpQuery-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                guard let url = input.file, url.isFileURL,
                      let info = FileSystem.info(of: url.path), info.isRegular, !info.dataless else {
                    throw SearchFailure("Choose a readable local file that has finished downloading.")
                }
                let embedding: Embedding
                // Prepare and validate before loading the full model.
                #if canImport(AVFoundation)
                switch input {
                case .image(let url):
                    let prepared = try ImageExtractor.prepare(url, maxPixel: 2048, minSide: 1, to: folder, png: true)
                    let worker = try runningWorker(media: true)
                    embedding = try worker.embedImages([prepared.path], budget: 280).first
                        ?? Embedding(vector: nil, error: "The image produced no embedding.")
                case .audio(let url, let start, let duration):
                    let path = try runBlocking { try await AudioExtractor.queryClip(of: url, start: start, duration: duration, to: folder) }
                    let worker = try runningWorker(media: true)
                    embedding = try worker.embedAudio([path.path]).first
                        ?? Embedding(vector: nil, error: "The audio produced no embedding.")
                case .text: fatalError("Text is handled above")
                }
                #else
                throw SearchFailure("Media queries currently require macOS.")
                #endif
                guard let vector = embedding.vector else { throw SearchFailure(embedding.error ?? "Cannot encode this attachment.") }
                return try checked(vector, source: mediaWorker!.info.vectorSource)
            } catch {
                // A failed helper is restarted on the next request.
                if error is WorkerError {
                    textWorker?.close(); mediaWorker?.close(); textWorker = nil; mediaWorker = nil
                }
                throw error
            }
        }
    }

    private func checked(_ values: [Float], source: String) throws -> EncodedQuery {
        guard values.count == Vectors.dimension, values.allSatisfy(\.isFinite) else {
            throw SearchFailure("The model returned an invalid search vector. Try the query again.")
        }
        return EncodedQuery(values: values, source: source)
    }

    private func runningWorker(media: Bool) throws -> EmbeddingWorker {
        if let worker = media ? mediaWorker : textWorker { return worker }
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent(ModelFiles.text.name).path),
              !media || FileManager.default.fileExists(atPath: models.appendingPathComponent(ModelFiles.media.name).path) else {
            throw SearchFailure("The search model is unavailable. Open DigUp Personal to finish downloading it.")
        }
        var config = WorkerConfig.helper(helper)
        config.environment["DIGUP_MODELS"] = models.path
        config.log = logs?.appendingPathComponent(media ? "worker-media-query.log" : "worker-query.log")
        config.qos = .userInitiated
        let worker = try EmbeddingWorker(config, textOnly: !media)
        if media { mediaWorker = worker } else { textWorker = worker }
        return worker
    }

    private func scheduleIdleExit() {
        idle?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.close() }
        idle = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + idleSeconds, execute: item)
    }
}

#if canImport(AVFoundation)
extension AudioExtractor {
    static func queryClip(of url: URL, start: Double, duration: Double, to folder: URL) async throws -> URL {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0, duration <= 30 else {
            throw SearchFailure("Choose a nonempty audio selection of at most 30 seconds.")
        }
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        guard total.isFinite, start < total, start + duration <= total + 0.02 else {
            throw SearchFailure("The selected clip is outside the recording.")
        }
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SearchFailure("This file has no audio track.")
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16000),
                                      duration: CMTime(seconds: duration, preferredTimescale: 16000))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SearchFailure("Cannot decode this recording.") }
        var samples = [Int16]()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var bytes = [Int16](repeating: 0, count: length / 2)
            let status = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw SearchFailure("Cannot decode the selected clip.") }
            samples.append(contentsOf: bytes)
        }
        guard reader.status == .completed else { throw reader.error ?? SearchFailure("Cannot finish decoding this clip.") }
        guard !samples.isEmpty, rms(samples[...]) > 0.003 else {
            throw SearchFailure("This selection is silent. Choose a section with speech, music, or sound.")
        }
        let out = folder.appendingPathComponent("query.wav")
        try writeWAV(samples[...], to: out)
        return out
    }
}
#endif
