import SwiftUI

struct ContentView: View {
    @State private var addresses = NetworkInfo.addresses()
    @State private var selectedIP = NetworkInfo.hotspotIP
    @State private var status: ServerStatus?
    @State private var shared: [String: Any] = [:]
    @State private var health = "—"
    @StateObject private var localNetwork = LocalNetworkPermission()
    @StateObject private var testServer = TestServer()
    @StateObject private var scanner = NetworkScanner()
    @State private var sharedFileExists = false
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selected: MirrorAddress {
        addresses.first { $0.ip == selectedIP } ?? addresses[0]
    }

    var body: some View {
        NavigationStack { mainContent }
    }

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("TeslaMirror").font(.largeTitle.bold())
                    Text("Recopie l'écran de l'iPhone dans le navigateur de la Tesla")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                statusCard
                diagnosticCard
                devicesCard
                testServerCard

                Label(status == nil ? "Démarrer la diffusion" : "Arrêter / gérer la diffusion",
                      systemImage: "record.circle")
                    .font(.title3.bold()).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding()
                    .background(status == nil ? Color.red : Color.gray, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { BroadcastPicker() }

                VStack(spacing: 12) {
                    Picker("Réseau", selection: $selectedIP) {
                        ForEach(addresses) { a in Text("\(a.label) — \(a.ip)").tag(a.ip) }
                    }
                    .pickerStyle(.menu)

                    Text(selected.url)
                        .font(.system(.title2, design: .monospaced).bold())
                        .textSelection(.enabled)

                    if let qr = QRCode.image(for: selected.url) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220).padding(12)
                            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    Text("Accueil : recopie d'écran + Netflix, YouTube… lus directement par la voiture")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                VStack(spacing: 0) {
                    NavigationLink { IPTVSettingsView() } label: {
                        settingsRow("TV (IPTV)", detail: "Liste M3U ou Xtream", icon: "tv")
                    }
                    Divider()
                    NavigationLink { PlexSettingsView() } label: {
                        settingsRow("Plex", detail: "Films et séries de votre serveur", icon: "play.rectangle")
                    }
                    Divider()
                    NavigationLink { JellyfinSettingsView() } label: {
                        settingsRow("Jellyfin", detail: "Films et séries de votre serveur", icon: "film.stack")
                    }
                }
                .background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Mode d'emploi").font(.headline)
                    Text("1. Activez le Partage de connexion et connectez la Tesla au Wi-Fi de l'iPhone.")
                    Text("2. Touchez « Démarrer la diffusion » puis choisissez TeslaMirror.")
                    Text("3. Dans le navigateur de la Tesla, ouvrez \(selected.url).")
                    Text("⚠️ Usage à l'arrêt uniquement. Aucun contrôle tactile depuis la voiture.")
                        .foregroundStyle(.orange)
                }
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .onReceive(timer) { _ in refresh() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { refresh() } }
        .onAppear {
            refresh(); localNetwork.request(); scanner.scan()
            // Évite le verrouillage auto tant que l'app est au premier plan (le relais vit dans la diffusion).
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var statusCard: some View {
        HStack {
            Circle().fill(status == nil ? Color.gray : Color.green).frame(width: 12, height: 12)
            if let s = status {
                Text("Diffusion active · \(s.mjpegClients + s.wsClients) client(s)")
                if let w = s.width, let h = s.height { Text("· \(w)×\(h)").foregroundStyle(.secondary) }
            } else {
                Text("Diffusion inactive").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout).padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var diagnosticCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostic").font(.headline)
            row("Réseau local", localNetworkText, color: localNetworkColor)
            row("Diffusion (extension)", sharedFileExists ? (shared["broadcast"] as? String ?? "—")
                : "aucun état écrit : l'extension n'a jamais démarré avec cette version",
                color: sharedFileExists ? .secondary : .orange)
            row("Serveur :\(shared["port"] as? Int ?? 8080)", shared["listener"] as? String ?? "—",
                color: (shared["listener"] as? String) == "ready" ? .green : .orange)
            row("Images reçues", "\(shared["frames"] as? Int ?? 0) · dernière MAJ \(ageText)")
            row("Mémoire extension", (shared["memoryMB"] as? Double).map { "\($0) Mo / ~50" } ?? "—")
            row("127.0.0.1:8080/health", health, color: health == "ok" ? .green : .orange)
            if localNetwork.state == .denied {
                Text("Autorisez TeslaMirror dans Réglages › Confidentialité et sécurité › Réseau local.")
                    .foregroundStyle(.orange)
            }
            Button("Redemander l'accès réseau local") { localNetwork.request() }
                .font(.footnote)
        }
        .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Appareils sur le partage").font(.headline)
                Spacer()
                if scanner.scanning { ProgressView() } else { Button("Scanner") { scanner.scan() } }
            }
            Text(scanner.subnetText).foregroundStyle(.secondary)
            if scanner.devices.isEmpty {
                Text(scanner.lastScan == nil ? "Touchez Scanner." : "Aucun appareil n'a répondu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.devices) { d in
                HStack {
                    Text(d.ip).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Text(d.via.sorted().joined(separator: ", ")).foregroundStyle(.secondary)
                }
            }
            Text("iOS ne publie pas les baux DHCP : chaque adresse du sous-réseau est sondée (ping + TCP). Un appareil qui ignore tout (pare-feu) peut ne pas apparaître ; il apparaîtra dans « Serveur test » dès qu'il s'y connecte.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var testServerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Serveur test (app)").font(.headline)
                Spacer()
                Button(testServer.running ? "Arrêter" : "Démarrer") {
                    testServer.running ? testServer.stop() : testServer.start()
                }
                .buttonStyle(.borderedProminent).tint(testServer.running ? .gray : .blue)
            }
            row("Listener :8080", testServer.state,
                color: testServer.state.hasPrefix("ready") ? .green : (testServer.state.hasPrefix("failed") ? .red : .secondary))
            Text("Arrêtez la diffusion, démarrez ce serveur, gardez l'app ouverte, puis ouvrez http://172.20.10.1:8080 dans la Tesla. « TeslaMirror OK » = réseau bon, le problème vient de l'extension.")
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(testServer.clients) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.address).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    Text("\(c.date.formatted(date: .omitted, time: .standard)) · \(c.request)").foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
        .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func settingsRow(_ title: String, detail: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon).frame(width: 28)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.secondary)
        }
        .padding().contentShape(Rectangle())
    }

    private func row(_ title: String, _ value: String, color: Color = .secondary) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(color).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    private var localNetworkText: String {
        switch localNetwork.state {
        case .unknown: return "inconnu"
        case .checking: return "vérification…"
        case .granted: return "accordé"
        case .denied: return "REFUSÉ"
        }
    }

    private var localNetworkColor: Color {
        switch localNetwork.state {
        case .granted: return .green
        case .denied: return .red
        default: return .secondary
        }
    }

    private var ageText: String {
        guard let t = shared["updatedAt"] as? Double else { return "—" }
        return "il y a \(Int(Date().timeIntervalSince1970 - t)) s"
    }

    private func refresh() {
        sharedFileExists = SharedStatus.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if let url = SharedStatus.fileURL, let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shared = obj
        }
        var healthRequest = URLRequest(url: URL(string: "http://127.0.0.1:8080/health")!)
        healthRequest.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: healthRequest) { data, _, error in
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? (error.map { ($0 as NSError).localizedDescription } ?? "?")
            DispatchQueue.main.async { health = text }
        }.resume()

        let current = NetworkInfo.addresses()
        if current != addresses { addresses = current }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/status")!)
        request.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let decoded = data.flatMap { try? JSONDecoder().decode(ServerStatus.self, from: $0) }
            DispatchQueue.main.async { status = decoded }
        }.resume()
    }
}

struct ServerStatus: Decodable {
    let mjpegClients: Int
    let wsClients: Int
    let width: Int?
    let height: Int?
}

#Preview { ContentView() }
