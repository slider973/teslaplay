import NetworkExtension

/// Tunnel « adresse virtuelle » : le navigateur Tesla refuse les IP privées (RFC 1918),
/// donc 172.20.10.1 est bloquée. Ce tunnel ne transporte rien : il attribue simplement à
/// l'iPhone les adresses 100.99.9.9 (validée dans la Tesla) et 198.18.9.9 (secours) sur son
/// interface utun, hors plages RFC 1918.
/// Un appareil du partage de connexion qui vise ces adresses atteint alors l'iPhone, et le
/// serveur TeslaMirror (qui écoute sur toutes les interfaces) répond.
///
/// Prototype : compte les paquets reçus par le tunnel et les écrit dans l'App Group
/// (tunnel.json) pour savoir si iOS livre localement ou route dans le tunnel.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let addresses = ["100.99.9.9", "198.18.9.9"]
    private var packets = 0
    private var destinations: [String] = []

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let ipv4 = NEIPv4Settings(addresses: Self.addresses, subnetMasks: Self.addresses.map { _ in "255.255.255.255" })
        ipv4.includedRoutes = []           // aucune route : le trafic normal de l'iPhone n'est pas touché
        settings.ipv4Settings = ipv4
        settings.mtu = 1500
        setTunnelNetworkSettings(settings) { [weak self] error in
            self?.write(state: error.map { "erreur: \($0.localizedDescription)" } ?? "actif")
            completionHandler(error)
            if error == nil { self?.readPackets() }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        write(state: "arrêté (\(reason.rawValue))")
        completionHandler()
    }

    private func readPackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.packets += packets.count
            for p in packets where self.destinations.count < 10 && p.count >= 20 && p[0] >> 4 == 4 {
                self.destinations.append("\(p[16]).\(p[17]).\(p[18]).\(p[19])")
            }
            self.write(state: "actif")
            self.readPackets()
        }
    }

    private func write(state: String) {
        var id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".Tunnel") { id.removeLast(".Tunnel".count) }
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group." + id) else { return }
        let obj: [String: Any] = ["state": state, "addresses": Self.addresses, "packets": packets,
                                  "destinations": destinations, "updatedAt": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: dir.appendingPathComponent("tunnel.json"), options: .atomic)
        }
    }
}
