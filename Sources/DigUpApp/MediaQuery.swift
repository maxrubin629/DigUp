import AppKit
import AVFoundation
import DigUpKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Shared ownership keeps a pasted image alive when a query moves between windows.
final class QueryAttachment {
    let input: SearchInput
    private let temporary: URL?
    init(_ input: SearchInput, temporary: URL? = nil) { self.input = input; self.temporary = temporary }
    deinit { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
}

struct AudioChoice: Identifiable {
    let id = UUID()
    let url: URL
    let duration: Double
}

@Observable
final class MediaQueryState {
    private static var pastedFiles = Set<URL>()
    static func cleanTemporaryFiles() {
        for file in pastedFiles { try? FileManager.default.removeItem(at: file) }
        pastedFiles.removeAll()
    }
    var attachment: QueryAttachment? { didSet { onChange() } }
    var input: SearchInput? { attachment?.input }
    var audioChoice: AudioChoice?
    var error: String? { didSet { if error != oldValue { onError() } } }
    var isSearching = false
    private var importing = false
    private var selectionGeneration = 0
    var isChoosing: Bool { importing || audioChoice != nil }
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored var onError: () -> Void = {}

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Search with an image or audio clip"
        importing = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.importing = false
            if response == .OK, let url = panel.url { self.select(url) }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }

    func select(_ url: URL) {
        selectionGeneration += 1
        let generation = selectionGeneration
        audioChoice = nil
        error = nil
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            attachment = QueryAttachment(.image(url))
        } else if type?.conforms(to: .audio) == true {
            Task {
                do {
                    let duration = try await SearchInput.audioDuration(of: url)
                    guard generation == selectionGeneration else { return }
                    if duration > 30 { audioChoice = AudioChoice(url: url, duration: duration) }
                    else { attachment = QueryAttachment(.audio(url, start: 0, duration: duration)) }
                } catch { if generation == selectionGeneration { self.error = error.localizedDescription } }
            }
        } else { error = "Choose an image or audio file." }
    }

    func editClip() {
        guard let url = input?.file else { return }
        Task {
            do { audioChoice = AudioChoice(url: url, duration: try await SearchInput.audioDuration(of: url)) }
            catch { self.error = error.localizedDescription }
        }
    }

    func remove() { selectionGeneration += 1; audioChoice = nil; attachment = nil; error = nil; isSearching = false }

    private func attachPNG(_ data: Data) {
        selectionGeneration += 1
        do {
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpClipboard-\(UUID().uuidString).png")
            try data.write(to: path, options: .atomic)
            Self.pastedFiles.insert(path)
            attachment = QueryAttachment(.image(path), temporary: path)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult
    func pasteImage() -> Bool {
        let board = NSPasteboard.general
        if let urls = board.readObjects(forClasses: [NSURL.self]) as? [URL],
           let url = urls.first, let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) || type.conforms(to: .audio) {
            select(url); return true
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
        attachPNG(png)
        return true
    }

    func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                Task { @MainActor in
                    if let url { self?.select(url) }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                Task { @MainActor in
                    guard let data, let image = NSImage(data: data), let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    self?.attachPNG(png)
                }
            }
            return true
        }
        return false
    }
}

struct MediaQueryButton: View {
    @Bindable var state: MediaQueryState

    var body: some View {
        HStack(spacing: 8) {
            if state.isSearching { ProgressView().controlSize(.small).accessibilityLabel("Searching attachment") }
            if case .audio(_, let start, let duration) = state.input {
                Button("\(start.formatted(.number.precision(.fractionLength(1))))–\((start + duration).formatted(.number.precision(.fractionLength(1)))) s") {
                    state.editClip()
                }
                .font(.system(size: 11).monospacedDigit())
                .help("Change the selected audio clip")
            }
            if state.input != nil {
                Button { state.remove() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Remove attachment").accessibilityLabel("Remove attachment")
            }
            Button { state.choose() } label: { Image(systemName: "paperclip") }
                .help("Search with an image or audio clip").accessibilityLabel("Attach image or audio")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .sheet(item: $state.audioChoice) { choice in
            AudioClipPicker(choice: choice) { start, duration in
                state.attachment = QueryAttachment(.audio(choice.url, start: start, duration: duration))
                state.audioChoice = nil
            } cancel: { state.audioChoice = nil }
        }
    }
}

private struct AudioClipPicker: View {
    let choice: AudioChoice
    let submit: (Double, Double) -> Void
    let cancel: () -> Void
    @State private var start = 0.0
    @State private var duration: Double
    @State private var player: AVPlayer
    @State private var boundary: Any?

    init(choice: AudioChoice, submit: @escaping (Double, Double) -> Void, cancel: @escaping () -> Void) {
        self.choice = choice; self.submit = submit; self.cancel = cancel
        _duration = State(initialValue: min(30, choice.duration))
        _player = State(initialValue: AVPlayer(url: choice.url))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose an audio clip").font(.title2.bold())
            Text(choice.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
            Text("Use up to 30 seconds as your search example.").font(.callout)
            HStack {
                Text("Start")
                Slider(value: $start, in: 0...max(0.01, choice.duration - min(0.1, choice.duration)))
                    .accessibilityLabel("Clip start")
                Text("\(start, specifier: "%.1f") s").monospacedDigit().frame(width: 75, alignment: .trailing)
            }
            HStack {
                Text("Length")
                Slider(value: $duration, in: min(0.1, choice.duration)...max(min(0.1, choice.duration), min(30, choice.duration - start)))
                    .accessibilityLabel("Clip length")
                Text("\(duration, specifier: "%.1f") s").monospacedDigit().frame(width: 75, alignment: .trailing)
            }
            HStack {
                Button("Play selection", systemImage: "play.fill") {
                    player.pause()
                    if let boundary { player.removeTimeObserver(boundary) }
                    player.seek(to: CMTime(seconds: start, preferredTimescale: 16000), toleranceBefore: .zero, toleranceAfter: .zero)
                    let playback = player
                    boundary = player.addBoundaryTimeObserver(
                        forTimes: [NSValue(time: CMTime(seconds: start + duration, preferredTimescale: 16000))],
                        queue: .main) { playback.pause() }
                    player.play()
                }
                Button("Stop") { player.pause() }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Search") { submit(start, min(duration, choice.duration - start)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 520)
        .onChange(of: start) { _, value in duration = min(duration, choice.duration - value); player.pause() }
        .onDisappear { player.pause(); if let boundary { player.removeTimeObserver(boundary) } }
    }
}
