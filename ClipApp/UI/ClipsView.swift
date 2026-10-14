import SwiftUI

struct ClipsView: View {
    @ObservedObject var library: ClipLibrary

    @State private var selection: URL?
    @State private var playing: ClipItem?
    @State private var renaming: ClipItem?
    @State private var newName = ""
    @State private var failure: Failure?

    private struct Failure {
        let title: String
        let message: String
    }

    var body: some View {
        Group {
            if let playing {
                ClipPlayerView(clip: playing) { self.playing = nil }
                    .id(playing.url)
            } else if !library.isLoaded {
                ProgressView()
            } else if library.clips.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        // A clip deleted or renamed behind the player's back closes it.
        .onChange(of: library.clips) { clips in
            if let playing, !clips.contains(where: { $0.url == playing.url }) { self.playing = nil }
        }
        .alert("Rename Clip", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename", action: commitRename)
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(verbatim: failure?.message ?? "")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)], spacing: 12) {
                ForEach(library.clips) { clip in
                    ClipCard(clip: clip, isSelected: selection == clip.url) {
                        actions(for: clip)
                    }
                    .onTapGesture { selection = clip.url }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { playing = clip })
                    .contextMenu { actions(for: clip) }
                }
            }
            .padding(16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No clips yet")
                .font(.title3)
            Text("Saved clips appear here. Press the clip shortcut or use the save button to keep the last seconds.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding()
    }

    @ViewBuilder
    private func actions(for clip: ClipItem) -> some View {
        Button("Play") { playing = clip }
        Divider()
        Button("Rename…") {
            newName = clip.name
            renaming = clip
        }
        Button("Reveal in Finder") { library.reveal(clip) }
        Button("Copy File") { library.copy(clip) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            do {
                try library.trash(clip)
            } catch {
                failure = Failure(title: String(localized: "Couldn't move the clip to the Trash"), message: error.localizedDescription)
            }
        }
    }

    private func commitRename() {
        guard let clip = renaming else { return }
        do {
            try library.rename(clip, to: newName)
        } catch {
            failure = Failure(title: String(localized: "Couldn't rename the clip"), message: error.localizedDescription)
        }
    }
}

private struct ClipCard<Actions: View>: View {
    let clip: ClipItem
    let isSelected: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipThumbnail(clip: clip)
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: clip.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(clip.name)
                    Text(verbatim: clip.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: details)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Menu(content: actions) {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(8)
        .background(
            isSelected ? Color.accentColor.opacity(0.25) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var details: String {
        let size = ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file)
        guard let duration = clip.duration else { return size }
        return "\(ClipFormat.duration(duration)) · \(size)"
    }
}

private struct ClipThumbnail: View {
    let clip: ClipItem
    @State private var image: NSImage?

    var body: some View {
        Color.black.opacity(0.25)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .task(id: clip.fingerprint) {
                image = await ThumbnailCache.shared.image(for: clip)
            }
    }
}

enum ClipFormat {
    /// `m:ss`, or `m:ss.t` with `tenths` for the trim controls.
    static func duration(_ seconds: TimeInterval, tenths: Bool = false) -> String {
        let total = max(0, seconds)
        if tenths {
            let whole = Int(total)
            return String(format: "%d:%02d.%d", whole / 60, whole % 60, Int((total - Double(whole)) * 10))
        }
        let rounded = Int(total.rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
