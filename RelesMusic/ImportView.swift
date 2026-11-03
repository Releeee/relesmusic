import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

struct SongRef: Hashable {
    let title: String
    let artist: String
}

struct AppleMusicPlaylist: Identifiable {
    let id: UInt64
    let name: String
    let songs: [SongRef]
}

enum PlaylistImporter {
    static func requestAppleMusicAccess() async -> Bool {
        await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Lee las playlists de la biblioteca de Apple Music de este iPhone.
    static func appleMusicPlaylists() -> [AppleMusicPlaylist] {
        let collections = MPMediaQuery.playlists().collections ?? []
        return collections.compactMap { collection -> AppleMusicPlaylist? in
            guard let playlist = collection as? MPMediaPlaylist else { return nil }
            let songs = playlist.items.compactMap { item -> SongRef? in
                guard let title = item.title else { return nil }
                return SongRef(title: title, artist: item.artist ?? "")
            }
            guard !songs.isEmpty else { return nil }
            return AppleMusicPlaylist(id: playlist.persistentID, name: playlist.name ?? "Sin nombre", songs: songs)
        }
    }

    /// Una canción por línea: «Artista - Título», o el .txt exportado de iTunes (separado por tabuladores).
    static func parse(_ text: String) -> [SongRef] {
        text.components(separatedBy: .newlines).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { return nil }
            if l.contains("\t") {
                let cols = l.components(separatedBy: "\t")
                guard !["Name", "Nombre"].contains(cols[0]) else { return nil }
                return SongRef(title: cols[0], artist: cols.count > 1 ? cols[1] : "")
            }
            if let r = l.range(of: " - ") {
                return SongRef(title: String(l[r.upperBound...]), artist: String(l[..<r.lowerBound]))
            }
            return SongRef(title: l, artist: "")
        }
    }
}

/// Busca cada canción en YouTube y crea la playlist.
@MainActor
final class ImportJob: ObservableObject {
    @Published var total = 0
    @Published var done = 0
    @Published var found = 0
    @Published var notFound: [String] = []
    @Published var isRunning = false
    @Published var finished = false

    func run(name: String, songs: [SongRef], library: Library) async {
        isRunning = true
        total = songs.count
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }

        var tracks: [Track] = []
        for song in songs {
            let query = song.artist.isEmpty ? song.title : "\(song.title) \(song.artist)"
            if let match = try? await YouTubeService.search(query).first {
                tracks.append(Track(
                    id: match.id,
                    title: song.title,
                    artist: song.artist.isEmpty ? match.artist : song.artist,
                    duration: match.duration
                ))
                found += 1
            } else {
                notFound.append(song.artist.isEmpty ? song.title : "\(song.artist) - \(song.title)")
            }
            done += 1
        }
        library.createPlaylist(name, tracks: tracks)
        isRunning = false
        finished = true
    }
}

struct ImportView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @StateObject private var job = ImportJob()

    @State private var applePlaylists: [AppleMusicPlaylist] = []
    @State private var appleLoaded = false
    @State private var appleDenied = false
    @State private var pastedName = "Importada"
    @State private var pastedText = ""
    @State private var showFilePicker = false

    var body: some View {
        NavigationStack {
            Group {
                if job.isRunning || job.finished {
                    progress
                } else {
                    form
                }
            }
            .navigationTitle("Importar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !job.isRunning { Button("Cerrar") { dismiss() } }
                }
            }
        }
        .interactiveDismissDisabled(job.isRunning)
    }

    private var form: some View {
        Form {
            Section {
                if !appleLoaded {
                    Button("Ver mis playlists de Apple Music") { Task { await loadApple() } }
                } else if appleDenied {
                    Text("Sin permiso. Actívalo en Ajustes › Rele's Music › Contenido multimedia y Apple Music.")
                        .foregroundStyle(.secondary)
                } else if applePlaylists.isEmpty {
                    Text("No se encontraron playlists.").foregroundStyle(.secondary)
                } else {
                    ForEach(applePlaylists) { playlist in
                        Button { start(playlist.name, playlist.songs) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(playlist.name).foregroundStyle(.primary)
                                    Text("\(playlist.songs.count) canciones").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.down")
                            }
                        }
                    }
                }
            } header: {
                Text("Desde Apple Music")
            } footer: {
                Text("Lee tus playlists de Apple Music en este iPhone y busca cada canción en YouTube. Hazlo antes de cancelar la suscripción.")
            }

            Section {
                TextField("Nombre de la playlist", text: $pastedName)
                TextEditor(text: $pastedText)
                    .frame(minHeight: 120)
                    .font(.callout)
                Button("Cargar archivo .txt") { showFilePicker = true }
                Button("Importar lista") { start(pastedName, PlaylistImporter.parse(pastedText)) }
                    .disabled(PlaylistImporter.parse(pastedText).isEmpty)
            } header: {
                Text("Pegar una lista")
            } footer: {
                Text("Una canción por línea, así: «Artista - Título». También vale el .txt que exporta iTunes.")
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.plainText, .text]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var encoding = String.Encoding.utf8
            if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
                pastedText = text
                pastedName = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private var progress: some View {
        VStack(spacing: 20) {
            ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                .tint(Color.rele)
            Text("\(job.done) de \(job.total)").font(.headline.monospacedDigit())
            if job.finished {
                Text("¡Listo! \(job.found) canciones importadas").font(.title3.bold())
                if !job.notFound.isEmpty {
                    List {
                        Section("No encontradas (\(job.notFound.count))") {
                            ForEach(job.notFound, id: \.self) { Text($0).font(.callout) }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
                Button("Hecho") { dismiss() }.buttonStyle(.borderedProminent)
            } else {
                Text("Buscando cada canción en YouTube… deja la app abierta.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding()
    }

    private func loadApple() async {
        let granted = await PlaylistImporter.requestAppleMusicAccess()
        appleDenied = !granted
        if granted { applePlaylists = PlaylistImporter.appleMusicPlaylists() }
        appleLoaded = true
    }

    private func start(_ name: String, _ songs: [SongRef]) {
        guard !songs.isEmpty else { return }
        Task { await job.run(name: name, songs: songs, library: library) }
    }
}
