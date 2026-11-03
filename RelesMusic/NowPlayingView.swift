import SwiftUI

struct NowPlayingView: View {
    @EnvironmentObject var player: Player
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, 360)
            VStack(spacing: 28) {
                Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
                Spacer(minLength: 0)
                if let track = player.current {
                    ArtworkView(track: track, size: side)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: Color.rele.opacity(0.5), radius: 30)

                    VStack(spacing: 6) {
                        Text(track.title).font(.title2.bold()).lineLimit(2).multilineTextAlignment(.center)
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                    }

                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(get: { scrubbing ?? player.currentTime }, set: { scrubbing = $0 }),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                if !editing, let s = scrubbing {
                                    player.seek(to: s)
                                    scrubbing = nil
                                }
                            }
                        )
                        HStack {
                            Text(formatTime(scrubbing ?? player.currentTime))
                            Spacer()
                            Text(formatTime(player.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button { player.toggleShuffle() } label: {
                            Image(systemName: "shuffle")
                                .foregroundStyle(player.shuffle ? Color.rele : .secondary)
                        }
                        Spacer()
                        Button { player.previous() } label: {
                            Image(systemName: "backward.fill").font(.title)
                        }
                        Spacer()
                        Button { player.togglePlay() } label: {
                            ZStack {
                                Circle().fill(Color.rele).frame(width: 72, height: 72)
                                if player.isLoading {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.title).foregroundStyle(.white)
                                }
                            }
                        }
                        Spacer()
                        Button { player.next() } label: {
                            Image(systemName: "forward.fill").font(.title)
                        }
                        Spacer()
                        Button { player.cycleRepeat() } label: {
                            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                                .foregroundStyle(player.repeatMode == .off ? .secondary : Color.rele)
                        }
                    }
                    .foregroundStyle(.primary)
                    .font(.title3)

                    if let error = player.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Color.rele.opacity(0.35), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }
}
