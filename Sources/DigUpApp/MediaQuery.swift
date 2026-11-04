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
    var start: Double = 0
    var length: Double? = nil
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
    var previewOpen = false
    var isSearching = false
    private var importing = false
    private var selectionGeneration = 0
    var isChoosing: Bool { importing || audioChoice != nil || previewOpen }
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
        previewOpen = false
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
        guard case .audio(let url, let start, let duration) = input else { return }
        let generation = selectionGeneration
        Task {
            do {
                let total = try await SearchInput.audioDuration(of: url)
                guard generation == selectionGeneration,
                      input == .audio(url, start: start, duration: duration) else { return }
                audioChoice = AudioChoice(url: url, duration: total, start: start, length: duration)
            } catch { if generation == selectionGeneration { self.error = error.localizedDescription } }
        }
    }

    func remove() { previewOpen = false; selectionGeneration += 1; audioChoice = nil; attachment = nil; error = nil; isSearching = false }

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
                Button("\(AudioClipSelection.timestamp(start))–\(AudioClipSelection.timestamp(start + duration))") {
                    state.editClip()
                }
                .font(.system(size: 11).monospacedDigit())
                .help("Change the selected audio clip")
            }
            if state.input != nil {
                Button { state.remove() } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Remove attachment").accessibilityLabel("Remove attachment")
            }
            Button { state.choose() } label: {
                if state.input != nil { Label("Replace", systemImage: "paperclip").font(.callout) }
                else { Image(systemName: "paperclip") }
            }
            .help("Search with an image or audio clip")
            .accessibilityLabel(state.input == nil ? "Attach image or audio" : "Replace attachment")
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
