import Foundation
import SwiftUI

struct Track: Codable, Identifiable, Hashable {
    let id: String          // ID del vídeo de YouTube
    var title: String
    var artist: String
    var duration: String?

    var thumbnailURL: URL? { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg") }
}

struct Playlist: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var tracks: [Track] = []
}

extension Color {
    static let rele = Color(red: 0.88, green: 0.0, blue: 1.0)
}

/// Guarda las playlists en un JSON dentro de la app.
@MainActor
final class Library: ObservableObject {
    @Published var playlists: [Playlist] = [] {
        didSet { save() }
    }

    private let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }

    var allTracks: [Track] {
        var seen = Set<String>()
        return playlists.flatMap(\.tracks).filter { seen.insert($0.id).inserted }
    }

    @discardableResult
    func createPlaylist(_ name: String, tracks: [Track] = []) -> Playlist {
        var seen = Set<String>()
        let unique = tracks.filter { seen.insert($0.id).inserted }
        let name = name.trimmingCharacters(in: .whitespaces)
        let playlist = Playlist(name: name.isEmpty ? "Nueva playlist" : name, tracks: unique)
        playlists.append(playlist)
        return playlist
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }),
              !playlists[i].tracks.contains(where: { $0.id == track.id }) else { return }
        playlists[i].tracks.append(track)
    }

    func remove(at offsets: IndexSet, from playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int, in playlistID: UUID) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[i].tracks.move(fromOffsets: source, toOffset: destination)
    }

    func rename(_ playlistID: UUID, to name: String) {
        guard let i = playlists.firstIndex(where: { $0.id == playlistID }),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        playlists[i].name = name
    }

    func deletePlaylists(at offsets: IndexSet) {
        playlists.remove(atOffsets: offsets)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
