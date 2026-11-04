import Foundation

/// A bounded query selection independent of the picker, so reopening and editing share the same rules.
public struct AudioClipSelection: Sendable, Equatable {
    public let recordingDuration: Double
    public private(set) var start: Double
    public private(set) var end: Double
    public var duration: Double { min(30, end - start) }
    public var minimumDuration: Double { min(0.1, recordingDuration) }

    public init(recordingDuration: Double, start: Double = 0, duration: Double? = nil) {
        self.recordingDuration = max(0.001, recordingDuration.isFinite ? recordingDuration : 0.001)
        let minimum = min(0.1, self.recordingDuration)
        self.start = min(max(0, start.isFinite ? start : 0), self.recordingDuration - minimum)
        let wanted = duration.flatMap { $0.isFinite ? $0 : nil } ?? 30
        end = min(self.recordingDuration, self.start + max(minimum, min(30, wanted)))
    }

    public static func validated(recordingDuration: Double, start: Double, end: Double) throws -> Self {
        guard start.isFinite, end.isFinite, start >= 0, end > start else {
            throw SearchFailure("Enter an end time after the start time.")
        }
        guard end <= recordingDuration else { throw SearchFailure("The clip must end within the recording.") }
        guard end - start <= 30.000001 else { throw SearchFailure("Choose a clip of at most 30 seconds.") }
        var result = Self(recordingDuration: recordingDuration)
        result.start = start
        result.end = end
        return result
    }

    /// Keep sub-decisecond accuracy when untouched labels are submitted; displayed rounding is not an edit.
    public func editing(startText: String, endText: String) throws -> Self {
        if startText == Self.timestamp(start), endText == Self.timestamp(end) { return self }
        guard let enteredStart = startText == Self.timestamp(start) ? start : Self.parseTime(startText),
              let enteredEnd = endText == Self.timestamp(end) ? end : Self.parseTime(endText) else {
            throw SearchFailure("Enter a time such as 1:24.5, or a number of seconds.")
        }
        return try Self.validated(recordingDuration: recordingDuration, start: enteredStart, end: enteredEnd)
    }

    public func movingStart(to time: Double) -> Self {
        var copy = self
        copy.start = min(max(max(0, end - 30), time), end - min(minimumDuration, duration))
        return copy
    }

    public func movingEnd(to time: Double) -> Self {
        var copy = self
        copy.end = max(start + min(minimumDuration, duration), min(min(recordingDuration, start + 30), time))
        return copy
    }

    /// Moves the whole range without changing its length, including at the recording's edges.
    public func movingSelection(to time: Double) -> Self {
        var copy = self
        copy.start = min(max(0, time), recordingDuration - duration)
        copy.end = copy.start + duration
        return copy
    }

    /// Accepts seconds, minutes:seconds, or hours:minutes:seconds, with fractional seconds.
    public static func parseTime(_ text: String) -> Double? {
        let pieces = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count) else { return nil }
        var values: [Double] = []
        for (index, piece) in pieces.enumerated() {
            guard !piece.isEmpty, piece.allSatisfy({ $0.isNumber || $0 == "." }),
                  let value = Double(piece), value.isFinite, value >= 0 else { return nil }
            if index < pieces.count - 1, value.rounded(.down) != value { return nil }
            if index > 0, value >= 60 { return nil }
            values.append(value)
        }
        let value = values.reduce(0) { $0 * 60 + $1 }
        return value.isFinite ? value : nil
    }

    public static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 10) else { return "0:00.0" }
        let tenths = Int((seconds * 10).rounded())
        let whole = tenths / 10
        if whole >= 3600 {
            return String(format: "%d:%02d:%02d.%d", whole / 3600, whole / 60 % 60, whole % 60, tenths % 10)
        }
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths % 10)
    }
}
