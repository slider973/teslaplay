import SwiftUI

struct PlexSettingsView: View {
    @State private var plex = PlexService()

    var body: some View {
        Form {
            switch plex.state {
            case .idle:
                Section {
                    Button("Se connecter à Plex") { plex.link() }
                } footer: {
                    Text("Une page plex.tv s'ouvre : connectez-vous puis revenez dans TeslaMirror.")
                }
            case .waitingForLink(let code):
                Section("En attente de la connexion…") {
                    Text("Code : \(code)").font(.title2.monospaced())
                    ProgressView()
                    Button("Annuler") { plex.disconnect() }
                }
            case .loadingServers:
                Section { ProgressView("Recherche des serveurs…") }
            case .choosing(let servers):
                Section("Choisissez un serveur") {
                    ForEach(servers) { server in
                        Button(server.name) { Task { await plex.choose(server) } }
                    }
                }
            case .testing(let name):
                Section { ProgressView("Test de \(name)…") }
            case .connected(let name):
                Section {
                    Label("Connecté à \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Changer de serveur") { Task { await plex.loadServers() } }
                    Button("Se déconnecter", role: .destructive) { plex.disconnect() }
                } footer: {
                    Text("Dans la voiture : http://100.99.9.9:8080 › Plex. La diffusion et l'accès Tesla doivent être actifs. Le serveur Plex doit être accessible à distance (Plex › Réglages › Accès à distance).")
                }
            case .error(let message):
                Section {
                    Text(message).foregroundStyle(.red)
                    Button("Réessayer") { plex.link() }
                }
            }
        }
        .navigationTitle("Plex")
    }
}
