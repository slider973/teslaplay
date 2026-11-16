import Foundation
import Observation

/// État partagé par les onglets : serveur de l'extension (via 127.0.0.1), état écrit dans
/// l'App Group, adresses réseau. Rafraîchi toutes les 2 s tant que l'app est affichée.
@MainActor @Observable
final class MirrorStatusModel {
    var addresses = NetworkInfo.addresses()
    var selectedIP = NetworkInfo.teslaIP
    private(set) var server: ServerStatus?
    private(set) var shared: [String: Any] = [:]
    private(set) var sharedFileExists = false
    private(set) var health = "—"
    private(set) var hotspotInUse = false

    var selected: MirrorAddress { addresses.first { $0.ip == selectedIP } ?? addresses[0] }
    var isBroadcasting: Bool { server != nil }
    var clientCount: Int { (server?.mjpegClients ?? 0) + (server?.wsClients ?? 0) }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh() async {
        sharedFileExists = SharedStatus.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if let url = SharedStatus.fileURL, let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            shared = object
        }
        let current = NetworkInfo.addresses()
        if current != addresses { addresses = current }
        hotspotInUse = NetworkScanner.currentSubnet()?.interface.hasPrefix("bridge") ?? false

        server = await Self.fetch("status").flatMap { try? JSONDecoder().decode(ServerStatus.self, from: $0) }
        health = await Self.fetch("health").map { String(decoding: $0, as: UTF8.self) } ?? "injoignable"
    }

    private static func fetch(_ path: String) async -> Data? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8080/\(path)")!)
        request.timeoutInterval = 1.5
        return try? await URLSession.shared.data(for: request).0
    }
}

struct ServerStatus: Decodable, Equatable {
    let mjpegClients: Int
    let wsClients: Int
    let audioClients: Int?
    let width: Int?
    let height: Int?
}
