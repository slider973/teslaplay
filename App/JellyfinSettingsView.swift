import SwiftUI

/// Connexion Jellyfin. Méthode principale : **connexion rapide** (Quick Connect) — un code à
/// 6 chiffres à valider depuis un appareil déjà connecté à Jellyfin, sans taper de mot de passe.
/// Repli : identifiant + mot de passe. Seul le jeton d'accès est conservé (App Group).
struct JellyfinSettingsView: View {
    @AppStorage("jellyfin.server") private var server = ""
    @AppStorage("jellyfin.user") private var user = ""
    @State private var password = ""
    @State private var connected = MediaConfig.jellyfin()
    @State private var quickCode: String?
    @State private var quickTask: Task<Void, Never>?
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
                    Text("Dans la voiture : http://100.99.9.9:8080 › Jellyfin. La diffusion et l'accès Tesla doivent être actifs, et le serveur Jellyfin joignable depuis internet.")
                }
            } else if let code = quickCode {
                Section {
                    Text(code)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .textSelection(.enabled)
                    HStack { ProgressView(); Text("En attente de validation…").foregroundStyle(.secondary) }
                    Button("Annuler", role: .cancel) { cancelQuickConnect() }
                } header: {
                    Text("Connexion rapide")
                } footer: {
                    Text("Sur un appareil déjà connecté à Jellyfin (site web ou app) : Profil › Connexion rapide, puis saisissez ce code. Il expire au bout de quelques minutes.")
                }
            } else {
                Section("Serveur Jellyfin") {
                    TextField("https://jellyfin.exemple.com", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button {
                        startQuickConnect()
                    } label: {
                        HStack {
                            Label("Connexion rapide", systemImage: "bolt.fill")
                            if loading { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(loading || server.isEmpty)
                } footer: {
                    Text("Recommandé : aucun mot de passe à saisir.")
                }
                Section {
                    DisclosureGroup("Avec identifiant et mot de passe") {
                        TextField("Utilisateur", text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("Mot de passe", text: $password)
                        Button("Se connecter") { Task { await login() } }
                            .disabled(loading || server.isEmpty || user.isEmpty)
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Jellyfin")
        .onDisappear { quickTask?.cancel() }
    }

    private func startQuickConnect() {
        error = nil
        loading = true
        quickTask?.cancel()
        quickTask = Task {
            defer { loading = false }
            do {
                let qc = try await JellyfinAuth.initiateQuickConnect(server: server, deviceId: deviceId)
                quickCode = qc.code
                loading = false
                for _ in 0..<100 {   // ~5 minutes
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if try await JellyfinAuth.quickConnectApproved(server: server, secret: qc.secret, deviceId: deviceId) {
                        let config = try await JellyfinAuth.completeQuickConnect(server: server, secret: qc.secret, deviceId: deviceId)
                        MediaConfig.saveJellyfin(config)
                        connected = config
                        quickCode = nil
                        return
                    }
                }
                quickCode = nil
                error = "Code expiré : recommencez."
            } catch is CancellationError {
            } catch {
                quickCode = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelQuickConnect() {
        quickTask?.cancel()
        quickTask = nil
        quickCode = nil
        loading = false
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
