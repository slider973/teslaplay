import SwiftUI

/// Sources lues directement par le navigateur de la voiture (image nette, son inclus).
struct MediaView: View {
    enum Route: Hashable { case iptv, plex, jellyfin }

    @Environment(MirrorStatusModel.self) private var model
    @AppStorage("iptv.summary") private var iptvSummary = ""
    @State private var plexName: String?
    @State private var jellyfinName: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: Route.iptv) {
                        sourceRow("TV", symbol: "antenna.radiowaves.left.and.right", color: .blue,
                                  status: iptvSummary.isEmpty ? nil : iptvSummary)
                    }
                    NavigationLink(value: Route.plex) {
                        sourceRow("Plex", symbol: "play.rectangle.fill", color: .orange,
                                  status: plexName.map { "Connecté à \($0)" })
                    }
                    NavigationLink(value: Route.jellyfin) {
                        sourceRow("Jellyfin", symbol: "film.stack.fill", color: .purple,
                                  status: jellyfinName.map { "Connecté à \($0)" })
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Dans la Tesla : \(model.selected.url), puis TV, Plex ou Jellyfin. La vidéo est décodée par la voiture : image nette et son par les haut-parleurs. La diffusion doit être active, c'est l'iPhone qui relaie.")
                }

                Section {
                    Label("Netflix, YouTube, Disney+, Prime Video… s'ouvrent depuis l'accueil de la page TeslaMirror et sont lus par la voiture elle-même.",
                          systemImage: "sparkles.tv")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Streaming")
                }
            }
            .navigationTitle("Médias")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .iptv: IPTVSettingsView()
                case .plex: PlexSettingsView()
                case .jellyfin: JellyfinSettingsView()
                }
            }
            .onAppear {
                plexName = MediaConfig.plex()?.name
                jellyfinName = MediaConfig.jellyfin()?.name
            }
        }
    }

    private func sourceRow(_ title: String, symbol: String, color: Color, status: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(color.gradient, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(status ?? "Non configuré")
                    .font(.footnote)
                    .foregroundStyle(status == nil ? Color.secondary : Color.green)
            }
        }
        .padding(.vertical, 4)
    }
}
