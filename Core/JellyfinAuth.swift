import Foundation

/// Connexion à un serveur Jellyfin (identifiant + mot de passe → jeton d'accès).
/// Utilisé par l'app (et le harnais) ; le résultat est rangé dans l'App Group (`jellyfin.json`).
enum JellyfinAuth {
    static func authorizationHeader(deviceId: String, token: String? = nil) -> String {
        var h = #"MediaBrowser Client="TeslaMirror", Device="Tesla", DeviceId="\#(deviceId)", Version="1.0""#
        if let token { h += #", Token="\#(token)""# }
        return h
    }

    static func normalize(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func login(server: String, username: String, password: String, deviceId: String) async throws -> MediaConfig.Jellyfin {
        let base = normalize(server)
        let (data, status) = try await send(base + "/Users/AuthenticateByName", method: "POST", deviceId: deviceId,
                                            body: ["Username": username, "Pw": password])
        if status == 401 { throw error("Identifiant ou mot de passe incorrect") }
        return try await config(fromAuthResult: data, status: status, base: base, deviceId: deviceId)
    }

    // MARK: - Connexion rapide (Quick Connect)

    struct QuickConnect {
        let secret: String
        let code: String
    }

    static func isQuickConnectEnabled(server: String) async -> Bool {
        guard let url = URL(string: normalize(server) + "/QuickConnect/Enabled"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return false }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Demande un code à 6 chiffres, à valider depuis un autre appareil déjà connecté à Jellyfin.
    static func initiateQuickConnect(server: String, deviceId: String) async throws -> QuickConnect {
        let base = normalize(server)
        var (data, status) = try await send(base + "/QuickConnect/Initiate", method: "POST", deviceId: deviceId)
        if status == 404 || status == 405 {   // serveurs < 10.9 : GET
            (data, status) = try await send(base + "/QuickConnect/Initiate", method: "GET", deviceId: deviceId)
        }
        if status == 401 || status == 403 { throw error("La connexion rapide est désactivée sur ce serveur (Tableau de bord › Général).") }
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secret = obj["Secret"] as? String, let code = obj["Code"] as? String else {
            throw error("Connexion rapide indisponible (\(status))")
        }
        return QuickConnect(secret: secret, code: code)
    }

    /// true quand le code a été validé.
    static func quickConnectApproved(server: String, secret: String, deviceId: String) async throws -> Bool {
        let base = normalize(server)
        let (data, status) = try await send(base + "/QuickConnect/Connect?secret=" + secret, method: "GET", deviceId: deviceId)
        if status == 404 { throw error("Code expiré : recommencez.") }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["Authenticated"] as? Bool ?? false
    }

    static func completeQuickConnect(server: String, secret: String, deviceId: String) async throws -> MediaConfig.Jellyfin {
        let base = normalize(server)
        let (data, status) = try await send(base + "/Users/AuthenticateWithQuickConnect", method: "POST",
                                            deviceId: deviceId, body: ["Secret": secret])
        return try await config(fromAuthResult: data, status: status, base: base, deviceId: deviceId)
    }

    // MARK: - Commun

    private static func send(_ urlString: String, method: String, deviceId: String,
                             body: [String: Any]? = nil) async throws -> (Data, Int) {
        guard let url = URL(string: urlString) else { throw error("Adresse invalide") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 15
        r.setValue(authorizationHeader(deviceId: deviceId), forHTTPHeaderField: "Authorization")
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: r)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func config(fromAuthResult data: Data, status: Int, base: String,
                               deviceId: String) async throws -> MediaConfig.Jellyfin {
        guard (200..<300).contains(status),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["AccessToken"] as? String,
              let user = obj["User"] as? [String: Any], let userId = user["Id"] as? String else {
            throw error("Réponse inattendue du serveur (\(status))")
        }
        var name = "Jellyfin"
        if let infoURL = URL(string: base + "/System/Info/Public"),
           let (d, _) = try? await URLSession.shared.data(from: infoURL),
           let info = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let serverName = info["ServerName"] as? String { name = serverName }
        return MediaConfig.Jellyfin(uri: base, token: token, userId: userId, name: name, deviceId: deviceId)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "Jellyfin", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
