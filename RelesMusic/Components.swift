import SwiftUI

struct ArtworkView: View {
    let track: Track
    var size: CGFloat

    var body: some View {
        AsyncImage(url: track.thumbnailURL) { image in
            // Escala para ocultar las franjas negras de las miniaturas 4:3
            image.resizable().scaledToFill().scaleEffect(1.34)
        } placeholder: {
            ZStack {
                Color.rele.opacity(0.2)
                Image(systemName: "music.note").foregroundStyle(Color.rele)
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }
}

struct TrackRow: View {
    @EnvironmentObject var player: Player
    let track: Track
    var onTap: () -> Void

    @State private var showAddToPlaylist = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                ArtworkView(track: track, size: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .lineLimit(1)
                        .foregroundStyle(player.current?.id == track.id ? Color.rele : .primary)
                    Text([track.artist, track.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)

            Menu {
                Button { showAddToPlaylist = true } label: {
                    Label("Añadir a playlist", systemImage: "text.badge.plus")
                }
                Button { player.playNext(track) } label: {
                    Label("Reproducir a continuación", systemImage: "text.insert")
                }
                Button { player.addToQueue(track) } label: {
                    Label("Añadir a la cola", systemImage: "text.append")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(track: track)
        }
    }
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Nueva playlist", text: $newName)
                        Button("Crear") {
                            library.createPlaylist(newName, tracks: [track])
                            dismiss()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Tus playlists") {
                    ForEach(library.playlists) { playlist in
                        Button {
                            library.add(track, to: playlist.id)
                            dismiss()
                        } label: {
                            HStack {
                                Text(playlist.name).foregroundStyle(.primary)
                                Spacer()
                                if playlist.tracks.contains(where: { $0.id == track.id }) {
                                    Image(systemName: "checkmark").foregroundStyle(Color.rele)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Añadir a playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var player: Player
    var onOpen: () -> Void

    var body: some View {
        if let track = player.current {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    ArtworkView(track: track, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if player.isLoading {
                        ProgressView().frame(width: 36)
                    } else {
                        Button { player.togglePlay() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title3).frame(width: 36, height: 36)
                        }
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36)
                    }
                }
                .foregroundStyle(.primary)
                .padding(8)

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.rele)
                        .frame(width: geo.size.width * progress)
                }
                .frame(height: 2)
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
        }
    }

    private var progress: CGFloat {
        player.duration > 0 ? CGFloat(min(player.currentTime / player.duration, 1)) : 0
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}
