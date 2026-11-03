import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var library: Library

    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var showImport = false

    var body: some View {
        NavigationStack {
            List {
                if !library.allTracks.isEmpty {
                    NavigationLink {
                        AllTracksView()
                    } label: {
                        Label("Todas las canciones", systemImage: "music.note")
                    }
                }
                Section("Playlists") {
                    ForEach(library.playlists) { playlist in
                        NavigationLink {
                            PlaylistView(playlistID: playlist.id)
                        } label: {
                            HStack(spacing: 12) {
                                if let first = playlist.tracks.first {
                                    ArtworkView(track: first, size: 52)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.rele.opacity(0.2))
                                        .frame(width: 52, height: 52)
                                        .overlay(Image(systemName: "music.note.list").foregroundStyle(Color.rele))
                                }
                                VStack(alignment: .leading) {
                                    Text(playlist.name)
                                    Text("\(playlist.tracks.count) canciones")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { library.deletePlaylists(at: $0) }
                }
            }
            .overlay {
                if library.playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.house").font(.system(size: 48)).foregroundStyle(Color.rele)
                        Text("Aún no tienes playlists").font(.headline)
                        Button("Importar desde Apple Music") { showImport = true }
                            .buttonStyle(.borderedProminent)
                        Button("Crear playlist") { showNewPlaylist = true }
                    }
                }
            }
            .navigationTitle("Rele's Music")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showNewPlaylist = true } label: {
                            Label("Nueva playlist", systemImage: "plus")
                        }
                        Button { showImport = true } label: {
                            Label("Importar playlists", systemImage: "square.and.arrow.down")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .alert("Nueva playlist", isPresented: $showNewPlaylist) {
                TextField("Nombre", text: $newName)
                Button("Crear") {
                    library.createPlaylist(newName)
                    newName = ""
                }
                Button("Cancelar", role: .cancel) { newName = "" }
            }
            .sheet(isPresented: $showImport) {
                ImportView()
            }
        }
    }
}

struct PlaylistView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    let playlistID: UUID

    @State private var showRename = false
    @State private var newName = ""

    private var playlist: Playlist? { library.playlists.first { $0.id == playlistID } }

    var body: some View {
        if let playlist {
            List {
                PlayButtons(tracks: playlist.tracks)
                ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { i, track in
                    TrackRow(track: track) { player.play(playlist.tracks, startAt: i) }
                }
                .onDelete { library.remove(at: $0, from: playlistID) }
                .onMove { library.move(from: $0, to: $1, in: playlistID) }
            }
            .listStyle(.plain)
            .navigationTitle(playlist.name)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            newName = playlist.name
                            showRename = true
                        } label: {
                            Label("Renombrar", systemImage: "pencil")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) { EditButton() }
            }
            .alert("Renombrar playlist", isPresented: $showRename) {
                TextField("Nombre", text: $newName)
                Button("Guardar") { library.rename(playlistID, to: newName) }
                Button("Cancelar", role: .cancel) {}
            }
        } else {
            Text("Esta playlist ya no existe").foregroundStyle(.secondary)
        }
    }
}

struct AllTracksView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let tracks = library.allTracks
        List {
            PlayButtons(tracks: tracks)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                TrackRow(track: track) { player.play(tracks, startAt: i) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Todas las canciones")
    }
}

struct PlayButtons: View {
    @EnvironmentObject var player: Player
    let tracks: [Track]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if player.shuffle { player.toggleShuffle() }
                player.play(tracks)
            } label: {
                Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                player.playShuffled(tracks)
            } label: {
                Label("Aleatorio", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .disabled(tracks.isEmpty)
        .listRowSeparator(.hidden)
    }
}
