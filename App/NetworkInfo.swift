import Foundation
import CoreImage.CIFilterBuiltins
import UIKit

struct MirrorAddress: Identifiable, Hashable {
    let label: String
    let ip: String
    var id: String { ip }
    var url: String { "http://\(ip):8080" }
}

enum NetworkInfo {
    static let hotspotIP = "172.20.10.1"
    /// Adresse virtuelle portée par le tunnel TeslaMirror : la seule que le navigateur Tesla accepte
    /// (il refuse les IP privées comme 172.20.10.1).
    static let teslaIP = "100.99.9.9"
    static let teslaBackupIP = "198.18.9.9"

    /// Adresses utilisables : partage de connexion (toujours proposé) + IPv4 détectées.
    static func addresses() -> [MirrorAddress] {
        var result = [MirrorAddress(label: "Tesla (tunnel)", ip: teslaIP),
                      MirrorAddress(label: "Tesla (secours)", ip: teslaBackupIP),
                      MirrorAddress(label: "Partage de connexion", ip: hotspotIP)]
        for (name, ip) in interfaceIPv4s() where ip != hotspotIP && ip != teslaIP && ip != teslaBackupIP {
            let label: String
            switch name {
            case "en0": label = "Wi-Fi"
            case let n where n.hasPrefix("bridge"): label = "Partage de connexion"
            default: label = name
            }
            if !result.contains(where: { $0.ip == ip }) { result.append(MirrorAddress(label: label, ip: ip)) }
        }
        return result
    }

    private static func interfaceIPv4s() -> [(String, String)] {
        var list: [(String, String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" || name.hasPrefix("bridge") || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                list.append((name, String(cString: host)))
            }
        }
        return list
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
