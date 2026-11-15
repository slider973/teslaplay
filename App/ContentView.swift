import SwiftUI

struct ContentView: View {
    @State private var addresses = NetworkInfo.addresses()
    @State private var selectedIP = NetworkInfo.hotspotIP
    @State private var status: ServerStatus?
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
        .onAppear { refresh() }
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

    /// L'app interroge directement le serveur de l'extension sur 127.0.0.1 : pas besoin d'App Group.
    private func refresh() {
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
