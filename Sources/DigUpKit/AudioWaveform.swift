#if canImport(AVFoundation)
import Foundation
@preconcurrency import AVFoundation

/// A fixed-size overview. Decoder buffers are released as they are read; long recordings do not accumulate PCM.
public enum AudioWaveform {
    public static func load(url: URL, buckets: Int = 800) async throws -> [Float] {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw SearchFailure("No audio waveform is available for this recording.")
        }
        let count = min(4096, max(16, buckets))
        let reader = try AVAssetReader(asset: asset)
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? SearchFailure("Cannot read the waveform.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var peaks = [Float](repeating: 0, count: count)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var samples = [Int16](repeating: 0, count: length / 2)
            let status = samples.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { throw SearchFailure("Cannot read the waveform.") }
            let first = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
            for (index, sample) in samples.enumerated() {
                let time = first + Double(index) / rate
                guard time.isFinite else { continue }
                let bucket = min(count - 1, max(0, Int(time / duration * Double(count))))
                peaks[bucket] = max(peaks[bucket], Float(abs(Int(sample))) / 32768)
            }
        }
        guard reader.status == .completed else { throw reader.error ?? SearchFailure("Cannot finish reading the waveform.") }
        return peaks
    }
}
#endif
