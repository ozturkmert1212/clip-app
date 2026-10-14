import SwiftUI

struct ClipsView: View {
    @ObservedObject var library: ClipLibrary
    let settings: SettingsStore
    /// The sidebar row this list belongs to; never `.settings`.
    let filter: SidebarItem

    @State private var selection: URL?
    @State private var playing: ClipItem?
    /// Bumped when the open clip was replaced on disk, to load it afresh.
    @State private var playerGeneration = 0
    @State private var renaming: ClipItem?
    @State private var newName = ""
    @State private var moving: [ClipItem] = []
    @State private var gameName = ""
    @State private var failure: ClipFailure?


    var body: some View {
        content
            .onChange(of: filter) { _ in playing = nil }
            .onChange(of: playing?.url) { _ in playerGeneration = 0 }
            // A clip deleted or renamed behind the player's back closes it.
            .onChange(of: library.items) { items in
                if let playing, !items.contains(where: { $0.url == playing.url }) { self.playing = nil }
            }
            .modifier(RenameAlert(clip: $renaming, name: $newName, commit: commitRename))
            .modifier(MoveAlert(clips: $moving, game: $gameName, commit: commitMove))
            .modifier(FailureAlert(failure: $failure))
    }

    @ViewBuilder
    private var content: some View {
        if let playing {
            ClipPlayerView(clip: playing, settings: settings, wasReplaced: playerGeneration > 0) { replaced in
                library.refresh()
                if replaced { playerGeneration += 1 }
            } onClose: {
                self.playing = nil
            }
            .id("\(playing.url.path)#\(playerGeneration)")
        } else if !library.isLoaded {
            ProgressView()
        } else if shown.isEmpty {
            emptyState
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 12)], spacing: 12) {
                ForEach(shown) { clip in
                    ClipCard(clip: clip, showsGame: filter == .allClips, isSelected: selection == clip.url) {
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

    private var shown: [ClipItem] {
        switch filter {
        case .allClips, .settings: return library.clips
        case .game(let name): return library.items.filter { $0.category == .game(name) }
        case .other: return library.items.filter { $0.category == .other }
        case .videos: return library.videos
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: filter == .videos ? "video" : "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(filter == .videos ? "No recordings yet" : "No clips yet")
                .font(.title3)
            Text(filter == .videos
                 ? "Recordings appear here. Start one from the sidebar, the menu or with the recording shortcut."
                 : "Saved clips appear here. Press the clip shortcut or use the save button to keep the last seconds.")
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
        if clip.category != .video {
            Button("Move to Game…") {
                if case .game(let name) = clip.category { gameName = name } else { gameName = "" }
                moving = [clip]
            }
        }
        Button("Reveal in Finder") { library.reveal([clip]) }
        Button("Copy File") { library.copy([clip]) }
        Divider()
        Button("Move to Trash", role: .destructive) {
            do {
                try library.trash([clip])
            } catch {
                failure = ClipFailure(title: AppLanguage.string("Couldn't move the clip to the Trash"), message: error.localizedDescription)
            }
        }
    }

    private func commitMove() {
        do {
            try library.move(moving, toGame: gameName)
        } catch {
            failure = ClipFailure(title: AppLanguage.string("Couldn't move the clip"), message: error.localizedDescription)
        }
    }

    private func commitRename() {
        guard let clip = renaming else { return }
        do {
            try library.rename(clip, to: newName)
        } catch {
            failure = ClipFailure(title: AppLanguage.string("Couldn't rename the clip"), message: error.localizedDescription)
        }
    }
}

struct ClipFailure {
    let title: String
    let message: String
}

private struct RenameAlert: ViewModifier {
    @Binding var clip: ClipItem?
    @Binding var name: String
    let commit: () -> Void

    func body(content: Content) -> some View {
        content.alert("Rename Clip", isPresented: Binding(get: { clip != nil }, set: { if !$0 { clip = nil } })) {
            TextField("Name", text: $name)
            Button("Rename", action: commit)
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct MoveAlert: ViewModifier {
    @Binding var clips: [ClipItem]
    @Binding var game: String
    let commit: () -> Void

    func body(content: Content) -> some View {
        content.alert("Move to Game", isPresented: Binding(get: { !clips.isEmpty }, set: { if !$0 { clips = [] } })) {
            TextField("Game", text: $game)
            Button("Move", action: commit)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clips are moved into this game's folder. A new name creates a new game.")
        }
    }
}

private struct FailureAlert: ViewModifier {
    @Binding var failure: ClipFailure?

    func body(content: Content) -> some View {
        content.alert(
            failure?.title ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") {}
        } message: {
            Text(verbatim: failure?.message ?? "")
        }
    }
}

private struct ClipCard<Actions: View>: View {
    let clip: ClipItem
    /// In lists that mix games, the card says which one it belongs to.
    let showsGame: Bool
    let isSelected: Bool
    @ViewBuilder let actions: () -> Actions

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ClipThumbnail(clip: clip)
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: clip.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(clip.name)
                    Text(verbatim: subtitle)
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

    private var subtitle: String {
        let date = clip.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
        guard showsGame, case .game(let name) = clip.category else { return date }
        return "\(name) · \(date)"
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
        if tenths {
            let total = Int((max(0, seconds) * 10).rounded())
            return String(format: "%d:%02d.%d", total / 600, total / 10 % 60, total % 10)
        }
        let rounded = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", rounded / 60, rounded % 60)
    }
}
