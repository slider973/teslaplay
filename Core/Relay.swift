import Foundation
import Network
import CryptoKit

/// Relais HTTP(S) amont → navigateur de la voiture, utilisé par le lecteur intégré (IPTV, Plex).
///
/// - Pas de proxy ouvert : le serveur ne relaie que des cibles résolues côté iPhone
///   (chaîne IPTV par index, serveur Plex configuré) ou des URL qu'il a lui-même réécrites
///   et signées (HMAC, clé aléatoire par session de diffusion).
/// - Contre-pression : la tâche amont est suspendue quand l'envoi vers le client prend du retard,
///   annulée à la déconnexion. Les flux continus (TS en direct) ne sont jamais mis en mémoire.
/// - Les playlists HLS (détectées par Content-Type ou par « #EXTM3U ») sont réécrites pour que
///   chaque segment repasse par le relais.
final class Relay: NSObject, URLSessionDataDelegate {
    static let maxJobs = 10
    static let suspendAbove = 2_000_000
    static let resumeBelow = 500_000
    static let maxPlaylistBytes = 2_000_000

    /// En-têtes à ajouter pour une URL amont donnée (jeton Plex pour l'hôte Plex, etc.).
    var headersForURL: ((URL) -> [String: String])?

    private let queue: DispatchQueue
    private var session: URLSession!
    private var jobs: [Int: Job] = [:]
    private let key = SymmetricKey(size: .bits256)

    private enum Mode { case undecided, stream, playlist }

    private final class Job {
        let conn: NWConnection
        let task: URLSessionDataTask
        var mode: Mode = .undecided
        var response: HTTPURLResponse?
        var buffer = Data()
        var pending = 0
        var suspended = false
        var headerSent = false
        var closed = false
        init(conn: NWConnection, task: URLSessionDataTask) { self.conn = conn; self.task = task }
    }

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
        let operations = OperationQueue()
        operations.underlyingQueue = queue          // tout l'état reste sur la file du serveur
        operations.maxConcurrentOperationCount = 1
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }

    var activeJobs: Int { jobs.count }

    func cancelAll() {
        for job in jobs.values { job.task.cancel(); job.conn.cancel() }
        jobs.removeAll()
    }

    // MARK: - Signature des URL réécrites

    func signedPath(for url: URL) -> String {
        let payload = Data(url.absoluteString.utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return "/r/" + Data(mac).prefix(9).base64URL + "/" + payload.base64URL
    }

    /// `rest` = ce qui suit « /r/ ». Retourne l'URL si la signature est valide.
    func verify(_ rest: Substring) -> URL? {
        let parts = rest.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let mac = Data(base64URL: String(parts[0])),
              let payload = Data(base64URL: String(parts[1])) else { return nil }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: payload, using: key)).prefix(9)
        guard mac == expected else { return nil }
        return URL(string: String(decoding: payload, as: UTF8.self))
    }

    // MARK: - Relais

    /// À appeler sur la file du serveur.
    func start(conn: NWConnection, url: URL, method: String, clientHeaders: [String: String]) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return Self.respondError(conn, "400 Bad Request", "URL refusée")
        }
        guard jobs.count < Self.maxJobs else {
            return Self.respondError(conn, "503 Service Unavailable", "Trop de flux simultanés")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
        request.setValue("VLC/3.0.20 LibVLC/3.0.20", forHTTPHeaderField: "User-Agent")
        for name in ["range", "accept", "accept-language"] {
            if let value = clientHeaders[name] { request.setValue(value, forHTTPHeaderField: name) }
        }
        for (name, value) in headersForURL?(url) ?? [:] { request.setValue(value, forHTTPHeaderField: name) }

        let task = session.dataTask(with: request)
        let job = Job(conn: conn, task: task)
        jobs[task.taskIdentifier] = job
        watchClose(job)
        task.resume()
    }

    private func watchClose(_ job: Job) {
        job.conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak job] _, _, isComplete, error in
            guard let self, let job, !job.closed else { return }
            if isComplete || error != nil { self.finish(job, cancelTask: true) } else { self.watchClose(job) }
        }
    }

    private func finish(_ job: Job, cancelTask: Bool) {
        guard !job.closed else { return }
        job.closed = true
        if cancelTask { job.task.cancel() }
        jobs.removeValue(forKey: job.task.taskIdentifier)
        // Ferme proprement après le dernier envoi en attente.
        job.conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [conn = job.conn] _ in conn.cancel() })
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = jobs[dataTask.taskIdentifier] else { return completionHandler(.cancel) }
        job.response = response as? HTTPURLResponse
        let mime = (response.mimeType ?? "").lowercased()
        if mime.contains("mpegurl") { job.mode = .playlist }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = jobs[dataTask.taskIdentifier], !job.closed else { return }
        if job.mode == .undecided {
            // Décision sur les premiers octets : jamais attendre la fin (un flux TS ne finit pas).
            job.mode = data.starts(with: Data("#EXTM3U".utf8)) ? .playlist : .stream
        }
        switch job.mode {
        case .playlist:
            job.buffer.append(data)
            if job.buffer.count > Self.maxPlaylistBytes {
                Self.respondError(job.conn, "502 Bad Gateway", "Playlist trop grande")
                finish(job, cancelTask: true)
            }
        case .stream, .undecided:
            if !job.headerSent { sendHeader(job, contentLength: job.response?.expectedContentLength) }
            send(data, to: job)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs[task.taskIdentifier], !job.closed else { return }
        if job.mode == .playlist, error == nil {
            let base = job.response?.url ?? task.originalRequest?.url ?? URL(string: "http://invalid/")!
            let text = rewritePlaylist(String(decoding: job.buffer, as: UTF8.self), base: base)
            let body = Data(text.utf8)
            job.buffer = Data()
            sendHeader(job, contentLength: Int64(body.count), contentType: "application/vnd.apple.mpegurl")
            send(body, to: job)
        } else if !job.headerSent {
            if let error {
                Self.respondError(job.conn, "502 Bad Gateway", "Source injoignable : \(error.localizedDescription)")
            } else {
                sendHeader(job, contentLength: 0)
            }
        }
        finish(job, cancelTask: false)
    }

    // MARK: - Envoi

    private func sendHeader(_ job: Job, contentLength: Int64?, contentType: String? = nil) {
        job.headerSent = true
        let r = job.response
        let status = r?.statusCode ?? 200
        var header = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        let type = contentType ?? (r?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream")
        header += "Content-Type: \(type)\r\n"
        if let len = contentLength, len >= 0, contentType != nil || r?.value(forHTTPHeaderField: "Content-Encoding") == nil {
            header += "Content-Length: \(len)\r\n"
        }
        for name in ["Content-Range", "Accept-Ranges"] {
            if let v = r?.value(forHTTPHeaderField: name) { header += "\(name): \(v)\r\n" }
        }
        header += "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        send(Data(header.utf8), to: job)
    }

    private func send(_ data: Data, to job: Job) {
        let size = data.count
        job.pending += size
        if job.pending > Self.suspendAbove && !job.suspended {
            job.suspended = true
            job.task.suspend()
        }
        job.conn.send(content: data, completion: .contentProcessed { [weak self, weak job] error in
            guard let self, let job else { return }
            job.pending -= size
            if error != nil { self.finish(job, cancelTask: true); return }
            if job.suspended && job.pending < Self.resumeBelow && !job.closed {
                job.suspended = false
                job.task.resume()
            }
        })
    }

    static func respondError(_ conn: NWConnection, _ status: String, _ message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Réécriture HLS

    private static let uriAttribute = try! NSRegularExpression(pattern: #"URI="([^"]+)""#)

    func rewritePlaylist(_ text: String, base: URL) -> String {
        var out: [String] = []
        text.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(line)
            } else if trimmed.hasPrefix("#") {
                let ns = line as NSString
                var result = line
                for match in Self.uriAttribute.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                    let value = ns.substring(with: match.range(at: 1))
                    if let abs = URL(string: value, relativeTo: base)?.absoluteURL {
                        result = (result as NSString).replacingCharacters(in: match.range(at: 1), with: self.signedPath(for: abs))
                    }
                }
                out.append(result)
            } else if let abs = URL(string: trimmed, relativeTo: base)?.absoluteURL {
                out.append(self.signedPath(for: abs))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
