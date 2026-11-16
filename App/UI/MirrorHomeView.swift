import SwiftUI

/// Écran principal : état, action principale (diffusion), adresse à taper dans la Tesla,
/// liste de vérification. Une seule action principale, en rouge.
struct MirrorHomeView: View {
    @Environment(MirrorStatusModel.self) private var model
    @EnvironmentObject private var tunnel: TunnelController
    @AppStorage("mirrorQuality", store: UserDefaults(suiteName: SharedStatus.appGroupID)) private var quality = "haute"
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.spacing) {
                    statusCard
                    broadcastButton
                    addressCard
                    checklistCard
                    qualityCard
                    Label("Usage à l'arrêt uniquement. Aucun contrôle tactile de l'iPhone depuis la voiture.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("TeslaMirror")
        }
    }

    // MARK: - État

    private var statusCard: some View {
        HStack(spacing: 14) {
            Image(systemName: model.isBroadcasting ? "dot.radiowaves.left.and.right" : "pause.circle")
                .font(.title)
                .symbolEffect(.variableColor.iterative, isActive: model.isBroadcasting)
                .foregroundStyle(model.isBroadcasting ? .green : .secondary)
                .frame(width: 52, height: 52)
                .background((model.isBroadcasting ? Color.green : Color.secondary).opacity(0.15), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isBroadcasting ? "Diffusion active" : "Prêt à diffuser")
                    .font(.title3.bold())
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private var statusDetail: String {
        guard let server = model.server else { return "Touchez « Démarrer la diffusion »." }
        var parts = [model.clientCount == 1 ? "1 navigateur connecté" : "\(model.clientCount) navigateurs connectés"]
        if let w = server.width, let h = server.height { parts.append("\(w)×\(h)") }
        if (server.audioClients ?? 0) > 0 { parts.append("son actif") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Action principale

    private var broadcastButton: some View {
        Label(model.isBroadcasting ? "Gérer la diffusion" : "Démarrer la diffusion",
              systemImage: model.isBroadcasting ? "stop.circle.fill" : "record.circle")
            .font(.title3.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(model.isBroadcasting ? Color.gray : Theme.accent, in: .rect(cornerRadius: 16))
            // Le vrai bouton système ReplayKit est posé par-dessus (seul moyen de lancer une diffusion).
            .overlay { BroadcastPicker() }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Ouvre le sélecteur de diffusion iOS ; choisissez TeslaMirror.")
    }

    // MARK: - Adresse

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dans le navigateur de la Tesla")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(model.selected.url)
                .font(.system(.title2, design: .monospaced).bold())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = model.selected.url
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(.bordered)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }

                if let qr = QRCode.image(for: model.selected.url) {
                    ShareLink(item: model.selected.url,
                              preview: SharePreview(model.selected.url, image: Image(uiImage: qr))) {
                        Label("Partager", systemImage: "qrcode")
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text("Depuis l'accueil : recopie d'écran, TV, Plex, Jellyfin, et Netflix, YouTube… lus directement par la voiture.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    // MARK: - Vérifications

    private var checklistCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Avant de partir").font(.headline)
            checkRow(model.hotspotInUse ? .ok : .pending,
                     title: "Partage de connexion",
                     detail: model.hotspotInUse ? "Un appareil est connecté à l'iPhone."
                                                : "Activez-le et connectez la Tesla au Wi-Fi de l'iPhone.")
            checkRow(tunnel.status == .connected ? .ok : .warning,
                     title: "Accès Tesla",
                     detail: tunnel.status == .connected ? "Adresse \(NetworkInfo.teslaIP) active."
                                                         : "Nécessaire : la Tesla refuse l'adresse du partage.") {
                if tunnel.status != .connected {
                    Button("Activer") { Task { await tunnel.start() } }
                        .buttonStyle(.bordered)
                }
            }
            checkRow(model.isBroadcasting ? .ok : .pending,
                     title: "Diffusion",
                     detail: model.isBroadcasting ? "L'iPhone sert la page à la voiture."
                                                  : "Nécessaire pour la recopie et pour relayer TV, Plex, Jellyfin.")
        }
        .card()
    }

    private func checkRow(_ kind: StatusIcon.Kind, title: String, detail: String,
                          @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(kind: kind)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).bold()
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            action()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(kind == .ok ? "fait" : "à faire")
    }

    // MARK: - Qualité

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Qualité de la recopie").font(.headline)
            Picker("Qualité de la recopie", selection: $quality) {
                Text("Haute · 1080p").tag("haute")
                Text("Standard · 720p").tag("standard")
            }
            .pickerStyle(.segmented)
            Text("Prise en compte au prochain démarrage de la diffusion. Dans la Tesla, touchez « Activer le son » pour entendre l'iPhone. Passez en Standard si la diffusion s'arrête seule.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}
