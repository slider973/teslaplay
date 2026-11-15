import Foundation
import Security
import UIKit

/// Connexion Plex depuis l'iPhone : code PIN plex.tv, choix du serveur, test des connexions.
/// Le résultat (adresse + jeton d'accès du serveur) est écrit dans l'App Group (`plex.json`)
/// pour l'extension. Le jeton n'est jamais envoyé au navigateur de la voiture.
@MainActor
final class PlexService: ObservableObject {
    struct Server: Identifiable, Hashable {
        let id: String
        let name: String
        let accessToken: String
        let uris: [String]   // ordre de préférence : distant direct, relais, local
    }

    enum State: Equatable {
        case idle
        case waitingForLink(code: String)
        case loadingServers
        case choosing([Server])
        case testing(String)
        case connected(String)
        case error(String)
    }

    @Published var state: State = .idle

    private let product = "TeslaMirror"
    private var pollTask: Task<Void, Never>?

    var clientId: String {
        if let id = UserDefaults.standard.string(forKey: "plex.clientId") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "plex.clientId")
        return id
    }

    init() {
        if let plex = MediaConfig.plex() { state = .connected(plex.name) }
    }

    private func request(_ url: String, method: String = "GET", token: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        r.setValue(clientId, forHTTPHeaderField: "X-Plex-Client-Identifier")
        r.setValue("1.0", forHTTPHeaderField: "X-Plex-Version")
        r.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        r.setValue("TeslaMirror", forHTTPHeaderField: "X-Plex-Device-Name")
        if let token { r.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
        return r
    }

    private func json(_ r: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: r)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "Plex", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Plex a répondu \(http.statusCode)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Liaison du compte (PIN)

    func link() {
        pollTask?.cancel()
        pollTask = Task {
            do {
                let pin = try await json(request("https://plex.tv/api/v2/pins?strong=true", method: "POST")) as? [String: Any]
                guard let id = pin?["id"] as? Int, let code = pin?["code"] as? String else {
                    throw NSError(domain: "Plex", code: 0, userInfo: [NSLocalizedDescriptionKey: "Réponse PIN inattendue"])
                }
                state = .waitingForLink(code: code)
                var comps = URLComponents(string: "https://app.plex.tv/auth")!
                comps.fragment = "?clientID=\(clientId)&code=\(code)&context%5Bdevice%5D%5Bproduct%5D=\(product)"
                if let url = comps.url { await UIApplication.shared.open(url) }

                for _ in 0..<150 {   // ~5 minutes
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let status = try await json(request("https://plex.tv/api/v2/pins/\(id)")) as? [String: Any]
                    if let token = status?["authToken"] as? String, !token.isEmpty {
                        KeychainStore.set("plex.userToken", token)
                        await loadServers()
                        return
                    }
                }
                state = .error("Délai dépassé : recommencez.")
            } catch is CancellationError {
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Serveurs

    func loadServers() async {
        guard let token = KeychainStore.get("plex.userToken") else { return link() }
        state = .loadingServers
        do {
            let list = try await json(request(
                "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=0",
                token: token)) as? [[String: Any]] ?? []
            let servers: [Server] = list.compactMap { r in
                guard (r["provides"] as? String ?? "").contains("server"),
                      let name = r["name"] as? String,
                      let id = r["clientIdentifier"] as? String else { return nil }
                let accessToken = r["accessToken"] as? String ?? token
                let conns = r["connections"] as? [[String: Any]] ?? []
                func rank(_ c: [String: Any]) -> Int {
                    let local = c["local"] as? Bool ?? false
                    let relay = c["relay"] as? Bool ?? false
                    return local ? 2 : (relay ? 1 : 0)
                }
                let uris = conns.sorted { rank($0) < rank($1) }.compactMap { $0["uri"] as? String }
                return uris.isEmpty ? nil : Server(id: id, name: name, accessToken: accessToken, uris: uris)
            }
            state = servers.isEmpty ? .error("Aucun serveur Plex sur ce compte.") : .choosing(servers)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Teste les adresses du serveur et garde la première qui répond.
    /// Les adresses locales ne marcheront pas dans la voiture : on préfère le distant / relais.
    func choose(_ server: Server) async {
        state = .testing(server.name)
        for uri in server.uris {
            var r = request(uri + "/identity", token: server.accessToken)
            r.timeoutInterval = 6
            if (try? await json(r)) != nil {
                let config = MediaConfig.Plex(uri: uri, token: server.accessToken, clientId: clientId, name: server.name)
                if let url = MediaConfig.groupFile("plex.json"), let data = try? JSONEncoder().encode(config) {
                    try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                state = .connected(server.name)
                return
            }
        }
        state = .error("\(server.name) ne répond sur aucune adresse. Activez l'accès à distance dans Plex.")
    }

    func disconnect() {
        pollTask?.cancel()
        KeychainStore.delete("plex.userToken")
        if let url = MediaConfig.groupFile("plex.json") { try? FileManager.default.removeItem(at: url) }
        state = .idle
    }
}

/// Petit coffre Keychain (mot de passe Xtream, jeton du compte Plex).
enum KeychainStore {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "TeslaMirror",
         kSecAttrAccount as String: key]
    }

    static func set(_ key: String, _ value: String) {
        SecItemDelete(query(key) as CFDictionary)
        var q = query(key)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ key: String) { SecItemDelete(query(key) as CFDictionary) }
}
