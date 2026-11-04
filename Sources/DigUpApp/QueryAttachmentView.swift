import AppKit
import DigUpKit
import SwiftUI

/// Keeps the search example visible alongside the results, in either window.
struct QueryAttachmentView: View {
    let input: SearchInput
    @Bindable var state: MediaQueryState

    var body: some View {
        Group {
            if case .image(let url) = input {
                Button { state.previewOpen = true } label: {
                    HStack(spacing: 10) {
                        QueryImage(url: url, side: 40)
                            .frame(width: 40, height: 40)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        title("Image search", name: input.label)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Preview the image used for this search")
                .accessibilityLabel("Preview search image, \(input.label)")
                .popover(isPresented: $state.previewOpen) {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Search image").font(.headline)
                            Spacer()
                            Button("Done") { state.previewOpen = false }.keyboardShortcut(.cancelAction)
                        }
                        QueryImage(url: url, side: 720)
                            .frame(width: 500, height: 360)
                        Text(input.label).font(.callout).textSelection(.enabled).lineLimit(2)
                    }
                    .padding(16)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                    title("Audio search", name: input.label)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(_ kind: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind).font(.caption).foregroundStyle(.secondary)
            Text(name).font(.system(size: 15, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
    }
}

private struct QueryImage: View {
    let url: URL
    let side: CGFloat
    @State private var image: NSImage?
    @State private var loaded = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if loaded {
                if side > 40 {
                    Label("Preview unavailable", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary).help("Preview unavailable")
                }
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: url) {
            image = nil; loaded = false
            let result = await Thumbnails.shared.load(url, side: side, scale: scale)
            guard !Task.isCancelled else { return }
            image = result; loaded = true
        }
    }
}
