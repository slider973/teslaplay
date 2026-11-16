import SwiftUI

/// Outillage technique, hors de l'écran principal : tunnel, extension, réseau, appareils
/// du partage, serveur de test.
struct DiagnosticsView: View {
    @Environment(MirrorStatusModel.self) private var model
    @Environment(TunnelController.self) private var tunnel
    @Environment(LocalNetworkPermission.self) private var localNetwork
    @State private var scanner = NetworkScanner()
    @State private var testServer = TestServer()

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                tunnelSection
                broadcastSection
                networkSection(selection: $model.selectedIP)
                devicesSection
                testServerSection
            }
            .navigationTitle("Diagnostic")
            .refreshable { await model.refresh(); tunnel.refreshInfo() }
            .onAppear {
                tunnel.refreshInfo()
                if scanner.lastScan == nil { scanner.scan() }
            }
        }
    }

    // MARK: - Accès Tesla

    private var tunnelSection: some View {
        Section {
            LabeledContent("Tunnel") {
                HStack(spacing: 6) {
                    Image(systemName: tunnel.status == .connected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                    Text(tunnel.statusText)
                }
                .foregroundStyle(tunnel.status == .connected ? .green : .secondary)
            }
            if tunnel.status == .connected {
                Button("Désactiver l'accès Tesla", role: .destructive) { tunnel.stop() }
            } else {
                Button("Activer l'accès Tesla") { Task { await tunnel.start() } }
            }
            if let error = tunnel.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Accès Tesla")
        } footer: {
            Text("Le navigateur Tesla refuse les adresses privées comme 172.20.10.1. Ce tunnel local donne à l'iPhone les adresses \(NetworkInfo.teslaIP) et \(NetworkInfo.teslaBackupIP). Aucune donnée ne passe par lui ni ne sort de l'iPhone.")
        }
    }

    // MARK: - Diffusion

    private var broadcastSection: some View {
        Section("Diffusion") {
            LabeledContent("Extension", value: model.sharedFileExists
                           ? (model.shared["broadcast"] as? String ?? "—")
                           : "jamais démarrée")
            LabeledContent("Serveur :8080") {
                let listener = model.shared["listener"] as? String ?? "—"
                Text(listener).foregroundStyle(listener == "ready" ? .green : .secondary)
            }
            LabeledContent("Images reçues", value: "\(model.shared["frames"] as? Int ?? 0)")
            LabeledContent("Mémoire de l'extension",
                           value: (model.shared["memoryMB"] as? Double).map { "\(Int($0)) Mo sur ~50" } ?? "—")
            LabeledContent("Réponse locale", value: model.health)
        }
    }

    // MARK: - Réseau

    private func networkSection(selection: Binding<String>) -> some View {
        Section {
            LabeledContent("Réseau local") {
                Text(localNetworkText).foregroundStyle(localNetwork.state == .denied ? .red : .secondary)
            }
            Button("Redemander l'accès réseau local") { localNetwork.request() }
            Picker("Adresse affichée", selection: selection) {
                ForEach(model.addresses) { address in
                    Text("\(address.label) · \(address.ip)").tag(address.ip)
                }
            }
        } header: {
            Text("Réseau")
        } footer: {
            if localNetwork.state == .denied {
                Text("Autorisez TeslaMirror dans Réglages › Confidentialité et sécurité › Réseau local.")
            }
        }
    }

    private var localNetworkText: String {
        switch localNetwork.state {
        case .unknown: "inconnu"
        case .checking: "vérification…"
        case .granted: "autorisé"
        case .denied: "refusé"
        }
    }

    // MARK: - Appareils

    private var devicesSection: some View {
        Section {
            if scanner.devices.isEmpty {
                Text(scanner.lastScan == nil ? "Recherche en cours…" : "Aucun appareil n'a répondu.")
                    .foregroundStyle(.secondary)
            }
            ForEach(scanner.devices) { device in
                LabeledContent {
                    Text(device.via.sorted().joined(separator: ", "))
                } label: {
                    Text(device.ip).monospaced().textSelection(.enabled)
                }
            }
            Button {
                scanner.scan()
            } label: {
                HStack {
                    Text("Rechercher les appareils")
                    if scanner.scanning { Spacer(); ProgressView() }
                }
            }
            .disabled(scanner.scanning)
        } header: {
            Text("Appareils sur le partage")
        } footer: {
            Text("\(scanner.subnetText). iOS ne publie pas les baux DHCP : chaque adresse est sondée (ping et TCP).")
        }
    }

    // MARK: - Serveur test

    private var testServerSection: some View {
        Section {
            Button(testServer.running ? "Arrêter le serveur test" : "Démarrer le serveur test") {
                testServer.running ? testServer.stop() : testServer.start()
            }
            if testServer.running {
                ForEach(testServer.ports, id: \.self) { port in
                    let state = testServer.states[port] ?? "arrêté"
                    LabeledContent("Port \(port)") {
                        Text(state).foregroundStyle(state == "ready" ? .green : (state.hasPrefix("failed") ? .red : .secondary))
                    }
                }
            }
            ForEach(testServer.clients) { client in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(client.address) → port \(client.port)").monospaced().textSelection(.enabled)
                    Text("\(client.date.formatted(date: .omitted, time: .standard)) · \(client.request)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Serveur test")
        } footer: {
            Text("Arrêtez la diffusion (même port) et gardez l'app ouverte, puis ouvrez \(model.selected.url) dans la Tesla. Chaque visite s'affiche ici.")
        }
    }
}
