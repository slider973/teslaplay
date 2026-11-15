import Foundation

/// Analyse une liste M3U/M3U Plus (IPTV) ligne à ligne et écrit les deux fichiers lus par
/// l'extension : `iptv-public.json` (noms, groupes, logos) et `iptv-urls.txt` (URL des flux).
/// Exécuté dans l'app (pas de limite mémoire stricte), jamais dans l'extension.
enum M3UParser {
    struct Result { let channels: Int; let groups: Int }
    static let maxChannels = 30_000

    /// Construit l'URL M3U d'un compte Xtream Codes (sortie HLS, la plus compatible navigateur).
    static func xtreamURL(server: String, username: String, password: String) -> URL? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.lowercased().hasPrefix("http") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        var c = URLComponents(string: base + "/get.php")
        c?.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "type", value: "m3u_plus"),
            URLQueryItem(name: "output", value: "m3u8"),
        ]
        return c?.url
    }

    static func parse(fileAt source: URL, outputDirectory dir: URL) async throws -> Result {
        var groups: [String] = []
        var groupIndex: [String: Int] = [:]
        var publicChannels: [[Any]] = []
        var urls = ""
        var pending: (name: String, group: String, logo: String)?

        for try await raw in source.lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                pending = parseExtInf(line)
            } else if line.hasPrefix("#") {
                if line.hasPrefix("#EXTGRP:"), let p = pending {
                    pending = (p.name, String(line.dropFirst(8)), p.logo)
                }
            } else if let info = pending ?? Optional((name: line, group: "", logo: "")) {
                pending = nil
                guard URL(string: line) != nil, publicChannels.count < maxChannels else { continue }
                let group = info.group.isEmpty ? "Sans groupe" : info.group
                let gi: Int
                if let existing = groupIndex[group] { gi = existing } else {
                    gi = groups.count; groups.append(group); groupIndex[group] = gi
                }
                publicChannels.append([info.name, gi, info.logo])
                urls += line + "\n"
            }
        }

        let json = try JSONSerialization.data(withJSONObject: ["groups": groups, "channels": publicChannels])
        try json.write(to: dir.appendingPathComponent("iptv-public.json"), options: .atomic)
        try Data(urls.utf8).write(to: dir.appendingPathComponent("iptv-urls.txt"), options: .atomic)
        return Result(channels: publicChannels.count, groups: groups.count)
    }

    /// `#EXTINF:-1 tvg-id="…" tvg-logo="…" group-title="…",Nom de la chaîne`
    static func parseExtInf(_ line: String) -> (name: String, group: String, logo: String) {
        var inQuotes = false
        var commaIndex: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() } else if c == ",", !inQuotes { commaIndex = i; break }
            i = line.index(after: i)
        }
        let attrs = commaIndex.map { String(line[..<$0]) } ?? line
        let name = commaIndex.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
        func attr(_ key: String) -> String {
            guard let r = attrs.range(of: key + "=\"") else { return "" }
            let rest = attrs[r.upperBound...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) } ?? ""
        }
        let tvgName = attr("tvg-name")
        return (name.isEmpty ? (tvgName.isEmpty ? "Chaîne" : tvgName) : name, attr("group-title"), attr("tvg-logo"))
    }
}
