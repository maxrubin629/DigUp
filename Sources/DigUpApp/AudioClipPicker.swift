import AVFoundation
import DigUpKit
import Observation
import SwiftUI

struct AudioClipPicker: View {
    let choice: AudioChoice
    let submit: (Double, Double) -> Void
    let cancel: () -> Void
    @State private var selection: AudioClipSelection
    @State private var startText: String
    @State private var endText: String
    @State private var inputError: String?
    @State private var waveform: [Float] = []
    @State private var waveformLoading = true
    @State private var waveformError: String?
    @State private var playback: ClipPlayback

    init(choice: AudioChoice, submit: @escaping (Double, Double) -> Void, cancel: @escaping () -> Void) {
        self.choice = choice
        self.submit = submit
        self.cancel = cancel
        let selected = AudioClipSelection(recordingDuration: choice.duration, start: choice.start, duration: choice.length)
        _selection = State(initialValue: selected)
        _startText = State(initialValue: AudioClipSelection.timestamp(selected.start))
        _endText = State(initialValue: AudioClipSelection.timestamp(selected.end))
        _playback = State(initialValue: ClipPlayback(url: choice.url, position: selected.start))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Choose an audio clip").font(.title2.bold())
                    Text(choice.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).help(choice.url.path)
                }
                Spacer()
                Text("Total \(AudioClipSelection.timestamp(choice.duration))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text("Select up to 30 seconds. Drag the highlighted clip to move it, or enter exact times.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ClipWaveform(peaks: waveform, selection: selection, playhead: playback.position, changed: changeSelection)
                    .frame(height: 108)
                    .overlay {
                        if waveformLoading { ProgressView("Reading waveform…").controlSize(.small) }
                    }
                HStack {
                    Text("0:00")
                    Spacer()
                    Text(AudioClipSelection.timestamp(choice.duration))
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let waveformError {
                Label(waveformError, systemImage: "waveform.slash").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                timestampField("Start", text: $startText)
                timestampField("End", text: $endText)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Selected").font(.caption).foregroundStyle(.secondary)
                    Text("\(selection.duration, specifier: "%.1f") / 30 s").monospacedDigit()
                }
            }
            if let inputError {
                Label(inputError, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
                    .accessibilityLabel(inputError)
            }
            if let error = playback.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button(playback.isPlaying ? "Pause" : "Play selection", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    if playback.isPlaying { playback.pause() } else { playback.play(selection) }
                }
                .disabled(inputError != nil)
                Text(AudioClipSelection.timestamp(playback.position)).font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary).accessibilityLabel("Playback position")
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Search") {
                    validateFields()
                    if inputError == nil { submit(selection.start, selection.duration) }
                }
                    .keyboardShortcut(.defaultAction).disabled(inputError != nil)
            }
        }
        .padding(24).frame(width: 620)
        .onChange(of: startText) { _, _ in validateFields() }
        .onChange(of: endText) { _, _ in validateFields() }
        .onAppear { playback.observe() }
        .onDisappear { playback.close() }
        .task(id: choice.id) {
            do {
                let peaks = try await AudioWaveform.load(url: choice.url)
                guard !Task.isCancelled else { return }
                waveform = peaks
            } catch is CancellationError { return }
            catch { waveformError = "Waveform unavailable. You can still enter times and play the selection." }
            waveformLoading = false
        }
    }

    private func timestampField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("m:ss.s", text: text)
                .textFieldStyle(.roundedBorder).font(.body.monospacedDigit()).frame(width: 120)
                .accessibilityLabel("Clip \(title.lowercased()) time")
                .help("Enter seconds, minutes:seconds, or hours:minutes:seconds")
                .onSubmit { validateFields() }
        }
    }

    private func validateFields() {
        playback.pause()
        do {
            let next = try selection.editing(startText: startText, endText: endText)
            if next != selection { selection = next; playback.reset(to: next.start) }
            inputError = nil
        } catch { inputError = error.localizedDescription }
    }

    private func changeSelection(_ next: AudioClipSelection) {
        selection = next
        startText = AudioClipSelection.timestamp(next.start)
        endText = AudioClipSelection.timestamp(next.end)
        inputError = nil
        playback.reset(to: next.start)
    }
}

private struct ClipWaveform: View {
    let peaks: [Float]
    let selection: AudioClipSelection
    let playhead: Double
    let changed: (AudioClipSelection) -> Void
    @State private var dragOrigin: AudioClipSelection?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - 16)
            let height = geometry.size.height
            let left = 8 + width * selection.start / selection.recordingDuration
            let right = 8 + width * selection.end / selection.recordingDuration
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                Canvas { context, size in
                    let maxPeak = max(Float(0.02), peaks.max() ?? 0)
                    var bars = Path()
                    for (index, peak) in peaks.enumerated() {
                        let x = 8 + width * (Double(index) + 0.5) / Double(peaks.count)
                        let amplitude = max(1, CGFloat(peak / maxPeak) * (height - 20) / 2)
                        bars.move(to: CGPoint(x: x, y: height / 2 - amplitude))
                        bars.addLine(to: CGPoint(x: x, y: height / 2 + amplitude))
                    }
                    context.stroke(bars, with: .color(.secondary.opacity(0.7)), lineWidth: max(1, width / Double(max(1, peaks.count)) * 0.6))
                }
                .allowsHitTesting(false)
                Color.clear.contentShape(Rectangle()).onTapGesture { point in
                    let time = min(1, max(0, (point.x - 8) / width)) * selection.recordingDuration
                    changed(selection.movingSelection(to: time - selection.duration / 2))
                }
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: max(2, right - left), height: height)
                    .offset(x: left)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                        if dragOrigin == nil { dragOrigin = selection }
                        if let origin = dragOrigin {
                            changed(origin.movingSelection(to: origin.start + value.translation.width / width * selection.recordingDuration))
                        }
                    }.onEnded { _ in dragOrigin = nil })
                    .accessibilityLabel("Selected audio clip")
                    .accessibilityValue("\(AudioClipSelection.timestamp(selection.start)) to \(AudioClipSelection.timestamp(selection.end))")
                    .accessibilityAdjustableAction { direction in
                        changed(selection.movingSelection(to: selection.start + (direction == .increment ? 1 : -1)))
                    }
                Rectangle().fill(Color.primary).frame(width: 2, height: height - 12)
                    .offset(x: 8 + width * min(1, max(0, playhead / selection.recordingDuration)), y: 6)
                    .allowsHitTesting(false).accessibilityHidden(true)
                handle("Clip start", x: left, width: width, height: height, start: true)
                handle("Clip end", x: right, width: width, height: height, start: false)
            }
        }
    }

    private func handle(_ label: String, x: Double, width: Double, height: Double, start: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor)
            .overlay(Image(systemName: "line.3.horizontal").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(90)).foregroundStyle(.white))
            .frame(width: 16, height: 36)
            .contentShape(Rectangle())
            .offset(x: x - 8, y: (height - 36) / 2)
            .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                if dragOrigin == nil { dragOrigin = selection }
                if let origin = dragOrigin {
                    let time = (start ? origin.start : origin.end) + value.translation.width / width * origin.recordingDuration
                    changed(start ? origin.movingStart(to: time) : origin.movingEnd(to: time))
                }
            }.onEnded { _ in dragOrigin = nil })
            .accessibilityLabel(label)
            .accessibilityValue(AudioClipSelection.timestamp(start ? selection.start : selection.end))
            .accessibilityAdjustableAction { direction in
                let time = (start ? selection.start : selection.end) + (direction == .increment ? 0.1 : -0.1)
                changed(start ? selection.movingStart(to: time) : selection.movingEnd(to: time))
            }
    }
}

@Observable
private final class ClipPlayback {
    private let player: AVPlayer
    private var observer: Any?
    private var boundary: Any?
    private var generation = 0
    var position: Double
    var isPlaying = false
    var error: String?

    init(url: URL, position: Double) { player = AVPlayer(url: url); self.position = position }

    func observe() {
        guard observer == nil else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isPlaying, time.seconds.isFinite { self.position = time.seconds }
                if self.player.status == .failed {
                    self.error = self.player.error?.localizedDescription ?? "Cannot play this recording."
                    self.pause()
                }
            }
        }
    }

    func play(_ selection: AudioClipSelection) {
        generation += 1
        let current = generation
        if let boundary { player.removeTimeObserver(boundary) }
        boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: selection.end, preferredTimescale: 16000))], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.pause(); self?.position = selection.end }
        }
        let target = position >= selection.start && position < selection.end - 0.03 ? position : selection.start
        player.seek(to: CMTime(seconds: target, preferredTimescale: 16000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, finished, current == self.generation else { return }
                self.position = target
                self.isPlaying = true
                self.player.play()
            }
        }
    }

    func pause() { generation += 1; player.pause(); isPlaying = false }
    func reset(to time: Double) { pause(); position = time }
    func close() {
        pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        if let boundary { player.removeTimeObserver(boundary); self.boundary = nil }
    }
}
