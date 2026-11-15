import SwiftUI

/// Saisie de la liste IPTV (URL M3U ou compte Xtream Codes). La liste est téléchargée et
/// analysée ici, dans l'app, puis écrite dans l'App Group pour l'extension.
struct IPTVSettingsView: View {
    enum Source: String, CaseIterable, Identifiable {
        case m3u = "Lien M3U", xtream = "Xtream Codes"
        var id: String { rawValue }
    }

    @AppStorage("iptv.source") private var source: Source = .m3u
    @AppStorage("iptv.m3u") private var m3uURL = ""
    @AppStorage("iptv.server") private var server = ""
    @AppStorage("iptv.user") private var user = ""
    @State private var password = KeychainStore.get("iptv.password") ?? ""
    @AppStorage("iptv.summary") private var summary = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Form {
            Picker("Type", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if source == .m3u {
                Section("Liste M3U") {
                    TextField("https://…/playlist.m3u", text: $m3uURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            } else {
                Section("Compte Xtream Codes") {
                    TextField("Serveur (ex. http://exemple.com:8080)", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Identifiant", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mot de passe", text: $password)
                }
            }

            Section {
                Button {
                    Task { await load() }
                } label: {
                    HStack {
                        Text(loading ? "Chargement…" : "Charger la liste")
                        if loading { Spacer(); ProgressView() }
                    }
                }
                .disabled(loading)
                if !summary.isEmpty { Text(summary).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("Dans la voiture : http://172.20.10.1:8080 › TV. La diffusion TeslaMirror doit être active : c'est l'iPhone qui relaie les flux.")
            }

            Section {
                Button("Supprimer la liste", role: .destructive) { clear() }
            }
        }
        .navigationTitle("IPTV")
    }

    private func load() async {
        error = nil
        let url: URL?
        switch source {
        case .m3u:
            url = URL(string: m3uURL.trimmingCharacters(in: .whitespacesAndNewlines))
        case .xtream:
            KeychainStore.set("iptv.password", password)
            url = M3UParser.xtreamURL(server: server, username: user, password: password)
        }
        guard let url, url.scheme?.hasPrefix("http") == true,
              let dir = MediaConfig.groupDirectory else {
            error = "Adresse invalide."
            return
        }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: url)
            request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let (file, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                error = "Le serveur a répondu \(http.statusCode)."
                return
            }
            let result = try await M3UParser.parse(fileAt: file, outputDirectory: dir)
            summary = "\(result.channels) chaînes, \(result.groups) groupes"
            if result.channels == 0 { error = "Aucune chaîne trouvée : vérifiez le lien." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clear() {
        for name in ["iptv-public.json", "iptv-urls.txt"] {
            if let url = MediaConfig.groupFile(name) { try? FileManager.default.removeItem(at: url) }
        }
        summary = ""
    }
}
