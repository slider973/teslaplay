import Foundation
import NetworkExtension
import Observation

/// Active / désactive le tunnel « adresse virtuelle » (extension TeslaMirrorTunnel).
@MainActor @Observable
final class TunnelController {
    private(set) var status: NEVPNStatus = .invalid
    private(set) var error: String?
    private(set) var info: [String: Any] = [:]
    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observer: NSObjectProtocol?

    static var providerBundleID: String { (Bundle.main.bundleIdentifier ?? "") + ".Tunnel" }

    init() { Task { await load() } }

    var statusText: String {
        switch status {
        case .invalid: return "non configuré"
        case .disconnected: return "inactif"
        case .connecting: return "démarrage…"
        case .connected: return "actif"
        case .reasserting: return "reconnexion…"
        case .disconnecting: return "arrêt…"
        @unknown default: return "?"
        }
    }

    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.providerBundleID }
            observe()
            status = manager?.connection.status ?? .invalid
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func observe() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let connection = manager?.connection else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: connection, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.status = connection.status }
        }
    }

    func start() async {
        error = nil
        do {
            let m = manager ?? NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = Self.providerBundleID
            proto.serverAddress = "TeslaMirror (local)"
            m.protocolConfiguration = proto
            m.localizedDescription = "TeslaMirror – accès Tesla"
            m.isEnabled = true
            // Toujours actif : relancé automatiquement par iOS (il ne transporte aucune donnée).
            m.onDemandRules = [NEOnDemandRuleConnect()]
            m.isOnDemandEnabled = true
            try await m.saveToPreferences()      // première fois : iOS demande d'autoriser la configuration VPN
            try await m.loadFromPreferences()    // indispensable avant le premier démarrage
            manager = m
            observe()
            try m.connection.startVPNTunnel()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        guard let m = manager else { return }
        Task {
            // Couper l'on-demand d'abord, sinon iOS relance aussitôt le tunnel.
            m.isOnDemandEnabled = false
            try? await m.saveToPreferences()
            m.connection.stopVPNTunnel()
        }
    }

    func refreshInfo() {
        guard let url = MediaConfig.groupFile("tunnel.json"), let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        info = obj
    }
}
