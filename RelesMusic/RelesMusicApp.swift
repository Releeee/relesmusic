import SwiftUI

@main
struct RelesMusicApp: App {
    @StateObject private var library = Library()
    @StateObject private var player = Player()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(library)
                .environmentObject(player)
                .tint(.rele)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @State private var showNowPlaying = false

    var body: some View {
        TabView {
            LibraryView()
                .modifier(MiniPlayerInset(showNowPlaying: $showNowPlaying))
                .tabItem { Label("Biblioteca", systemImage: "music.note.list") }
            SearchView()
                .modifier(MiniPlayerInset(showNowPlaying: $showNowPlaying))
                .tabItem { Label("Buscar", systemImage: "magnifyingglass") }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView()
        }
    }
}

struct MiniPlayerInset: ViewModifier {
    @EnvironmentObject var player: Player
    @Binding var showNowPlaying: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom) {
            if player.current != nil {
                MiniPlayer { showNowPlaying = true }
            }
        }
    }
}
