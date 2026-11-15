import SwiftUI

/// Connexion Jellyfin : adresse du serveur + identifiants. Seul le jeton d'accès est conservé
/// (App Group, pour l'extension) ; le mot de passe n'est pas stocké.
struct JellyfinSettingsView: View {
    @AppStorage("jellyfin.server") private var server = ""
    @AppStorage("jellyfin.user") private var user = ""
    @State private var password = ""
    @State private var connected = MediaConfig.jellyfin()
    @State private var loading = false
    @State private var error: String?

    private var deviceId: String {
        if let id = UserDefaults.standard.string(forKey: "jellyfin.deviceId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "jellyfin.deviceId")
        return id
    }

    var body: some View {
        Form {
            if let jf = connected {
                Section {
                    Label("Connecté à \(jf.name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(jf.uri).font(.footnote).foregroundStyle(.secondary)
                    Button("Se déconnecter", role: .destructive) {
                        MediaConfig.saveJellyfin(nil)
                        connected = nil
                    }
                } footer: {
                    Text("Dans la voiture : http://172.20.10.1:8080 › Jellyfin. La diffusion TeslaMirror doit être active, et le serveur Jellyfin joignable depuis internet (adresse publique ou nom de domaine).")
                }
            } else {
                Section("Serveur Jellyfin") {
                    TextField("https://jellyfin.exemple.com", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Utilisateur", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mot de passe", text: $password)
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            Text(loading ? "Connexion…" : "Se connecter")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading || server.isEmpty || user.isEmpty)
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Jellyfin")
    }

    private func login() async {
        error = nil
        loading = true
        defer { loading = false }
        do {
            let config = try await JellyfinAuth.login(server: server, username: user, password: password, deviceId: deviceId)
            MediaConfig.saveJellyfin(config)
            password = ""
            connected = config
        } catch {
            self.error = error.localizedDescription
        }
    }
}
