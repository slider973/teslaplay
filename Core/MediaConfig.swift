import Foundation

/// Configuration du lecteur intégré, écrite par l'app dans l'App Group, lue par l'extension.
///
/// - `plex.json`        : { "uri", "token", "clientId", "name" } — jamais envoyé au navigateur.
/// - `jellyfin.json`    : { "uri", "token", "userId", "name", "deviceId" } — jeton jamais envoyé au navigateur.
/// - `iptv-public.json` : { "groups": [...], "channels": [[nom, indexGroupe, logo], ...] } — servi tel quel.
/// - `iptv-urls.txt`    : une URL de flux par ligne (même ordre) — peut contenir des identifiants,
///                        n'est jamais envoyé au navigateur ; lu ligne à ligne (mémoire minimale).
enum MediaConfig {
    struct Plex: Codable {
        var uri: String
        var token: String
        var clientId: String
        var name: String
    }

    struct Jellyfin: Codable {
        var uri: String
        var token: String
        var userId: String
        var name: String
        var deviceId: String
    }

    static func jellyfin() -> Jellyfin? {
        guard let url = file("jellyfin.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Jellyfin.self, from: data)
    }

    static func saveJellyfin(_ config: Jellyfin?) {
        guard let url = file("jellyfin.json") else { return }
        if let config, let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func jellyfinHeaders(_ jf: Jellyfin) -> [String: String] {
        ["Authorization": JellyfinAuth.authorizationHeader(deviceId: jf.deviceId, token: jf.token),
         "X-Emby-Token": jf.token]
    }

    static var groupDirectory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStatus.appGroupID)
    }

    static func groupFile(_ name: String) -> URL? {
        groupDirectory?.appendingPathComponent(name)
    }

    /// Permet au harnais macOS (sans App Group) de pointer vers un dossier.
    static var overrideDirectory: URL?

    static func file(_ name: String) -> URL? {
        if let dir = overrideDirectory { return dir.appendingPathComponent(name) }
        return groupFile(name)
    }

    static func plex() -> Plex? {
        guard let url = file("plex.json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Plex.self, from: data)
    }

    /// Données de la liste publique, mappées en mémoire (ne comptent pas comme mémoire sale).
    static func iptvPublicData() -> Data? {
        guard let url = file("iptv-public.json") else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// URL de la chaîne n° `index`, lue en flux depuis `iptv-urls.txt`.
    static func iptvURL(index: Int) -> URL? {
        guard index >= 0, let url = file("iptv-urls.txt"), let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var line = 0
        var current = Data()
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            for byte in chunk {
                if byte == 0x0A {
                    if line == index { return URL(string: String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
                    line += 1
                    current.removeAll(keepingCapacity: true)
                } else if line == index {
                    current.append(byte)
                }
            }
        }
        if line == index, !current.isEmpty {
            return URL(string: String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func plexHeaders(_ plex: Plex) -> [String: String] {
        [
            "X-Plex-Token": plex.token,
            "X-Plex-Client-Identifier": plex.clientId,
            "X-Plex-Product": "TeslaMirror",
            "X-Plex-Version": "1.0",
            "X-Plex-Platform": "Chrome",
            "X-Plex-Device": "Tesla",
            "X-Plex-Device-Name": "TeslaMirror",
        ]
    }
}
