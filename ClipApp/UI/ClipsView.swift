import SwiftUI

struct ClipsView: View {
    @ObservedObject var library: ClipLibrary
    let settings: SettingsStore
    /// The sidebar row this list belongs to; never `.settings`.
    let filter: SidebarItem

    @State private var selection: Set<URL> = []
    /// Where a Shift-click range starts: the clip clicked last without Shift.
    @State private var anchor: URL?
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
            .onChange(of: filter) { _ in
                playing = nil
                selection = []
            }
            .onChange(of: playing?.url) { _ in playerGeneration = 0 }
            // A clip deleted or renamed behind the player's back closes it.
            .onChange(of: library.items) { items in
                if let playing, !items.contains(where: { $0.url == playing.url }) { self.playing = nil }
                selection.formIntersection(items.map(\.url))
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
        VStack(spacing: 0) {
            if !selection.isEmpty {
                selectionBar
                Divider()
            }
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 216, maximum: 340), spacing: Brand.Space.two)],
                    spacing: Brand.Space.two
                ) {
                    ForEach(shown) { clip in
                        ClipCard(clip: clip, showsGame: filter == .allClips, isSelected: selection.contains(clip.url)) {
                            actions(for: clip)
                        }
                        .onTapGesture { select(clip) }
                        .simultaneousGesture(TapGesture(count: 2).onEnded { playing = clip })
                        .contextMenu { actions(for: clip) }
                    }
                }
                .padding(Brand.Space.two)
            }
        }
        // Command-A, both as the Edit menu's Select All and as a plain shortcut.
        .onCommand(#selector(NSText.selectAll(_:))) { selectAll() }
        .background {
            Button("Select All", action: selectAll)
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
        }
    }

    /// How many clips are selected and what can be done with all of them.
    private var selectionBar: some View {
        let clips = selected
        return HStack(spacing: Brand.Space.one) {
            Text("\(clips.count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Spacer()
            if filter != .videos {
                Button("Move to Game…") { beginMove(clips) }
            }
            Button("Reveal in Finder") { library.reveal(clips) }
            Button(clips.count > 1 ? "Copy Files" : "Copy File") { library.copy(clips) }
            Button("Move to Trash", role: .destructive) { trash(clips) }
            Button("Deselect") { selection = [] }
        }
        .padding(.horizontal, Brand.Space.two)
        .padding(.vertical, Brand.Space.one)
    }

    /// The selected clips in the order they are listed.
    private var selected: [ClipItem] {
        shown.filter { selection.contains($0.url) }
    }

    /// A plain click selects one clip, Command adds or removes one, Shift
    /// extends from the last plainly clicked clip.
    private func select(_ clip: ClipItem) {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            selection.formSymmetricDifference([clip.url])
            anchor = clip.url
        } else if modifiers.contains(.shift), let anchor,
                  let from = shown.firstIndex(where: { $0.url == anchor }),
                  let to = shown.firstIndex(where: { $0.url == clip.url }) {
            selection = Set(shown[min(from, to)...max(from, to)].map(\.url))
        } else {
            selection = [clip.url]
            anchor = clip.url
        }
    }

    private func selectAll() {
        guard playing == nil else { return }
        selection = Set(shown.map(\.url))
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
        EmptyStateView(
            title: filter == .videos ? "No recordings yet" : "No clips yet",
            message: filter == .videos
                ? "Recordings appear here. Start one from the sidebar, the menu or with the recording shortcut."
                : "Saved clips appear here. Press the clip shortcut or use the save button to keep the last seconds."
        )
    }

    /// For a clip that is part of a larger selection the menu acts on all of
    /// it; otherwise on that clip alone.
    @ViewBuilder
    private func actions(for clip: ClipItem) -> some View {
        let targets = selection.contains(clip.url) && selection.count > 1 ? selected : [clip]
        if targets.count == 1 {
            Button("Play") { playing = clip }
            Divider()
            Button("Rename…") {
                newName = clip.name
                renaming = clip
            }
        } else {
            Text("\(targets.count) selected")
        }
        if targets.contains(where: { $0.category != .video }) {
            Button("Move to Game…") { beginMove(targets) }
        }
        Button("Reveal in Finder") { library.reveal(targets) }
        Button(targets.count > 1 ? "Copy Files" : "Copy File") { library.copy(targets) }
        Divider()
        Button("Move to Trash", role: .destructive) { trash(targets) }
    }

    private func beginMove(_ clips: [ClipItem]) {
        // Starts from the game the clips are in, if they share one.
        let games = Set(clips.map(\.category))
        if games.count == 1, case .game(let name) = clips[0].category { gameName = name } else { gameName = "" }
        moving = clips
    }

    private func trash(_ clips: [ClipItem]) {
        do {
            try library.trash(clips)
        } catch {
            failure = ClipFailure(
                title: clips.count > 1
                    ? AppLanguage.string("Couldn't move the clips to the Trash")
                    : AppLanguage.string("Couldn't move the clip to the Trash"),
                message: error.localizedDescription
            )
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: Brand.Space.one) {
            ClipThumbnail(clip: clip)
                .overlay(alignment: .bottomTrailing) {
                    if let duration = clip.duration {
                        Text(verbatim: ClipFormat.duration(duration))
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, Brand.Space.one)
                            .padding(.vertical, Brand.Space.half / 2)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .padding(Brand.Space.one)
                    }
                }
            HStack(alignment: .top, spacing: Brand.Space.half) {
                VStack(alignment: .leading, spacing: Brand.Space.half) {
                    Text(verbatim: clip.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(clip.name)
                    Text(verbatim: subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: clip.size, countStyle: .file))
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
        .padding(Brand.Space.one)
        .background(shape.fill(isSelected ? Brand.fill.opacity(0.18) : Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(border, lineWidth: isSelected ? 2 : 1))
        .shadow(color: Color.black.opacity(isHovered ? 0.2 : 0), radius: isHovered ? 8 : 0, y: isHovered ? 3 : 0)
        .offset(y: isHovered && !reduceMotion ? -1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }

    /// Selected: a firm indigo frame. Under the pointer: a thin one. Otherwise a hairline.
    private var border: Color {
        if isSelected { return Brand.accentText }
        return isHovered ? Brand.accentText.opacity(0.7) : Brand.hairline
    }

    private var subtitle: String {
        let date = clip.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(locale))
        guard showsGame, case .game(let name) = clip.category else { return date }
        return "\(name) · \(date)"
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
            .clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
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
