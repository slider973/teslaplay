import SwiftUI

struct ContentView: View {
    @State private var addresses = NetworkInfo.addresses()
    @State private var selectedIP = NetworkInfo.hotspotIP
    @State private var status: ServerStatus?
    @State private var shared: [String: Any] = [:]
    @State private var health = "—"
    @StateObject private var localNetwork = LocalNetworkPermission()
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var selected: MirrorAddress {
        addresses.first { $0.ip == selectedIP } ?? addresses[0]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("TeslaMirror").font(.largeTitle.bold())
                    Text("Recopie l'écran de l'iPhone dans le navigateur de la Tesla")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }

                statusCard
                diagnosticCard

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
                    Text("/ = H.264 (faible latence) · /mjpeg = MJPEG (compatibilité)")
                        .font(.footnote).foregroundStyle(.secondary)
                }

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
        .onAppear { refresh(); localNetwork.request() }
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
            row("Diffusion (extension)", shared["broadcast"] as? String ?? "jamais lancée")
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
