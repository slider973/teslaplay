import Foundation
import Network
import Darwin
import Observation

/// Liste les appareils connectés au partage de connexion de l'iPhone.
///
/// iOS ne donne accès ni aux baux DHCP ni à la table ARP. On sonde donc chaque adresse du
/// sous-réseau du partage (172.20.10.0/28 → 14 adresses) : ping ICMP (socket non privilégiée)
/// + tentative TCP sur quelques ports. Toute réponse — même un refus de connexion — prouve
/// qu'un appareil est présent. Sonder le réseau local déclenche aussi la demande
/// d'autorisation « Réseau local » d'iOS.
@MainActor @Observable
final class NetworkScanner {
    struct Device: Identifiable, Hashable, Sendable {
        var id: String { ip }
        let ip: String
        var via: Set<String>
    }

    private(set) var devices: [Device] = []
    private(set) var scanning = false
    private(set) var subnetText = "—"
    private(set) var lastScan: Date?

    nonisolated private static let probePorts: [UInt16] = [80, 443, 8080, 62078, 7000, 22]

    struct Subnet { let own: UInt32; let mask: UInt32; let interface: String }

    /// Interface du partage de connexion (bridgeXXX), ou à défaut le Wi-Fi (en0).
    nonisolated static func currentSubnet() -> Subnet? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var bridge: Subnet?, wifi: Subnet?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let maskPtr = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if name.hasPrefix("bridge") { bridge = Subnet(own: ip, mask: mask, interface: name) }
            if name == "en0" { wifi = Subnet(own: ip, mask: mask, interface: name) }
        }
        return bridge ?? wifi
    }

    nonisolated static func string(_ ip: UInt32) -> String {
        "\(ip >> 24 & 0xFF).\(ip >> 16 & 0xFF).\(ip >> 8 & 0xFF).\(ip & 0xFF)"
    }

    func scan() {
        guard !scanning else { return }
        guard let subnet = Self.currentSubnet() else {
            subnetText = "Aucun appareil connecté au partage (interface bridge absente) et pas de Wi-Fi."
            devices = []
            return
        }
        // Limite à 254 hôtes (un /24) pour rester rapide.
        let mask = max(subnet.mask, 0xFFFF_FF00)
        let network = subnet.own & mask
        let broadcast = network | ~mask
        let hosts = (network + 1 ..< broadcast).filter { $0 != subnet.own }
        let label = subnet.interface.hasPrefix("bridge") ? "Partage de connexion" : "Wi-Fi"
        subnetText = "\(label) (\(subnet.interface)) · iPhone = \(Self.string(subnet.own))"
        scanning = true

        let ips = hosts.map(Self.string)
        Task {
            let list = await Task.detached(priority: .userInitiated) { Self.probe(ips) }.value
            devices = list
            scanning = false
            lastScan = Date()
        }
    }

    /// Sonde une liste d'adresses (bloquant, ~3 s). Exposé pour les tests.
    nonisolated static func probe(_ ips: [String]) -> [Device] {
        var found: [String: Set<String>] = [:]
        let lock = NSLock()
        func mark(_ ip: String, _ how: String) { lock.lock(); found[ip, default: []].insert(how); lock.unlock() }

        for ip in ping(ips) { mark(ip, "ping") }

        let group = DispatchGroup()
        let q = DispatchQueue(label: "teslamirror.scan", attributes: .concurrent)
        for ip in ips {
            for port in probePorts {
                group.enter()
                tcpProbe(ip: ip, port: port, queue: q) { alive in
                    if alive { mark(ip, "tcp \(port)") }
                    group.leave()
                }
            }
        }
        group.wait()
        return found.map { Device(ip: $0.key, via: $0.value) }
            .sorted { $0.ip.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes($1.ip.split(separator: ".").compactMap { Int($0) }) }
    }

    /// Connexion TCP : établie ou refusée (RST) ⇒ l'appareil existe. Délai dépassé ⇒ inconnu.
    nonisolated private static func tcpProbe(ip: String, port: UInt16, queue: DispatchQueue, done: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var finished = false
        let lock = NSLock()
        func finish(_ alive: Bool) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            conn.cancel()
            done(alive)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(true)
            case .waiting(let e), .failed(let e):
                if case .posix(let code) = e, code == .ECONNREFUSED { finish(true) } else { finish(false) }
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 1.5) { finish(false) }
    }

    /// Ping ICMP via socket datagramme (autorisée sans privilèges sur iOS).
    nonisolated private static func ping(_ ips: [String]) -> Set<String> {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard sock >= 0 else { return [] }
        defer { close(sock) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let ident = UInt16.random(in: 1...0xFFFE)
        for (seq, ip) in ips.enumerated() {
            var packet: [UInt8] = [8, 0, 0, 0, UInt8(ident >> 8), UInt8(ident & 0xFF), UInt8(seq >> 8 & 0xFF), UInt8(seq & 0xFF)]
            packet += Array("TeslaMirror".utf8)
            let sum = checksum(packet)
            packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, ip, &addr.sin_addr)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sock, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var alive = Set<String>()
        let deadline = Date().addingTimeInterval(1.5)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while Date() < deadline {
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(sock, &buffer, buffer.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            // Darwin peut inclure l'en-tête IP : on saute jusqu'à l'ICMP.
            let offset = (buffer[0] >> 4) == 4 ? Int(buffer[0] & 0x0F) * 4 : 0
            guard n > offset, buffer[offset] == 0 else { continue }   // 0 = echo reply
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &from.sin_addr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
            alive.insert(String(cString: ipBuf))
        }
        return alive
    }

    nonisolated private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum += UInt32(data[i]) << 8 | UInt32(data[i + 1]); i += 2 }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
