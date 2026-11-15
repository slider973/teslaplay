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
        guard let url = URL(string: base + "/Users/AuthenticateByName") else { throw error("Adresse invalide") }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 15
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(authorizationHeader(deviceId: deviceId), forHTTPHeaderField: "Authorization")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw error("Identifiant ou mot de passe incorrect") }
        guard (200..<300).contains(status),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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
