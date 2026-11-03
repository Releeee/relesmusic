import SwiftUI

struct SearchView: View {
    @EnvironmentObject var player: Player

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var showLink = false
    @State private var linkText = ""

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
                ForEach(results) { track in
                    TrackRow(track: track) { player.play([track]) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if results.isEmpty && !isSearching && errorMessage == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(Color.rele)
                        Text("Busca canciones, artistas o remixes de YouTube")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Pegar enlace de YouTube") { pasteLink() }
                    }
                    .padding()
                }
            }
            .searchable(text: $query, prompt: "Canciones, artistas, remixes…")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Buscar")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { pasteLink() } label: { Image(systemName: "link.badge.plus") }
                }
            }
            .alert("Añadir desde enlace", isPresented: $showLink) {
                TextField("https://youtu.be/…", text: $linkText)
                Button("Abrir") { Task { await openLink() } }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Pega el enlace de un vídeo de YouTube")
            }
        }
    }

    private func pasteLink() {
        linkText = UIPasteboard.general.string ?? ""
        showLink = true
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        // Si pegan un enlace en el buscador, ábrelo directamente
        if YouTubeService.videoID(from: q) != nil, q.contains("youtu") {
            linkText = q
            await openLink()
            return
        }
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await YouTubeService.search(q)
            if results.isEmpty { errorMessage = "Sin resultados" }
            player.prefetch(results)
        } catch {
            errorMessage = "Error al buscar. Revisa tu conexión."
        }
    }

    private func openLink() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            let track = try await YouTubeService.track(fromLink: linkText)
            results = [track]
            player.prefetch(results)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
