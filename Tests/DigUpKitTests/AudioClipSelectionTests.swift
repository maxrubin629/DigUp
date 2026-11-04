import Foundation
import Testing
@testable import DigUpKit

@Suite struct AudioClipSelectionTests {
    @Test func reopeningPreservesTheChosenPassage() {
        let selection = AudioClipSelection(recordingDuration: 3600, start: 742.5, duration: 12.8)
        #expect(selection.start == 742.5)
        #expect(abs(selection.duration - 12.8) < 0.000001)
        let reopened = AudioClipSelection(recordingDuration: 3600, start: selection.start, duration: selection.duration)
        #expect(reopened == selection)
        let short = AudioClipSelection(recordingDuration: 3.5)
        #expect(short.start == 0 && short.end == 3.5)
    }

    @Test func untouchedTimestampFieldsRetainFractionalAndTinyClips() throws {
        for selection in [
            AudioClipSelection(recordingDuration: 40.06, start: 31.92, duration: 8.14),
            AudioClipSelection(recordingDuration: 0.04),
            AudioClipSelection(recordingDuration: 40, start: 31.92, duration: 8.08)
        ] {
            let submitted = try selection.editing(startText: AudioClipSelection.timestamp(selection.start),
                                                 endText: AudioClipSelection.timestamp(selection.end))
            #expect(submitted == selection)
        }
        let fractionalEnd = AudioClipSelection(recordingDuration: 40.06, start: 31.92, duration: 8.14)
        let changedStart = try fractionalEnd.editing(startText: "0:33.0", endText: "0:40.1")
        #expect(changedStart.start == 33 && changedStart.end == 40.06)
        let changedEnd = try fractionalEnd.editing(startText: "0:31.9", endText: "0:39.0")
        #expect(changedEnd.start == 31.92 && changedEnd.end == 39)
        let original = AudioClipSelection(recordingDuration: 40, start: 32, duration: 3)
        let edited = try original.editing(startText: "0:33.0", endText: "0:36.0")
        #expect(edited.start == 33 && edited.end == 36)
    }

    @Test func draggingKeepsTheClipInsideTheRecordingAndUnderThirtySeconds() {
        let selection = AudioClipSelection(recordingDuration: 100, start: 40, duration: 10)
        #expect(selection.movingStart(to: 0).start == 20)
        #expect(selection.movingEnd(to: 99).end == 70)
        let nearEnd = selection.movingSelection(to: 99)
        #expect(nearEnd.start == 90 && nearEnd.end == 100 && nearEnd.duration == 10)
        let nearStart = selection.movingSelection(to: -20)
        #expect(nearStart.start == 0 && nearStart.end == 10)
        #expect(selection.movingStart(to: 999).duration > 0)
        #expect(selection.movingEnd(to: -1).duration > 0)
    }

    @Test func timestampsAcceptPreciseEntriesAndRejectAmbiguity() {
        #expect(AudioClipSelection.parseTime("1:24.5") == 84.5)
        #expect(AudioClipSelection.parseTime("1:02:03.2") == 3723.2)
        #expect(AudioClipSelection.parseTime(" 84.5 ") == 84.5)
        for invalid in ["", ":30", "2:60", "1.5:20", "-2", "nan", "inf", "1:2:3:4"] {
            #expect(AudioClipSelection.parseTime(invalid) == nil)
        }
        #expect(AudioClipSelection.timestamp(84.5) == "1:24.5")
        #expect(AudioClipSelection.timestamp(3599.99) == "1:00:00.0")
    }

    @Test func typedRangesFailClearlyInsteadOfSilentlyChangingThePassage() throws {
        let valid = try AudioClipSelection.validated(recordingDuration: 4000, start: 3600.25, end: 3630.25)
        #expect(valid.duration == 30)
        for (start, end) in [(4.0, 4.0), (8, 5), (-1, 5), (2, 33), (3990, 4001)] {
            #expect(throws: SearchFailure.self) {
                try AudioClipSelection.validated(recordingDuration: 4000, start: start, end: end)
            }
        }
    }

    #if canImport(AVFoundation)
    @Test func waveformUsesFixedBucketsAndRetainsSilenceLocations() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpWaveform-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.wav")
        let samples = (0..<64000).map { index -> Int16 in
            index < 32000 ? 0 : Int16(12000 * sin(Double(index) * 0.1))
        }
        try AudioExtractor.writeWAV(samples[...], to: path)
        let peaks = try await AudioWaveform.load(url: path, buckets: 80)
        #expect(peaks.count == 80)
        #expect(peaks.prefix(35).allSatisfy { $0 < 0.001 })
        #expect(peaks.suffix(35).allSatisfy { $0 > 0.1 })
        let cancelled = Task { try await AudioWaveform.load(url: path) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
    #endif
}
