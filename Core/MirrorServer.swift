import Foundation
import Network
import CryptoKit

/// Serveur HTTP/WebSocket minimal (Network.framework) écoutant sur 0.0.0.0:<port>.
///
/// Routes :
///   GET /        → accueil : recopie d'écran + raccourcis vers les services lus par la voiture
///   GET /mirror  → lecteur H.264 (MSE + WebSocket), repli automatique vers /mjpeg
///   GET /mjpeg   → page MJPEG (<img src="/stream">)
///   GET /stream  → flux multipart/x-mixed-replace (JPEG)
///   GET /ws      → WebSocket : texte {"type":"init","codec":…} puis init segment fMP4, puis fragments
///   GET /wsa     → WebSocket audio : {"type":"init","codec":"mp4a.40.2"}, init fMP4 AAC, puis fragments
///   GET /status  → JSON (rotation, clients…)
///   GET /health  → "ok"
///
/// Tout l'état est confiné à `queue` (série). Aucun envoi n'est mis en file sans limite :
/// MJPEG saute les images quand le client est lent, WebSocket jette jusqu'à la prochaine keyframe.
final class MirrorServer {
    static let maxClients = 6
    static let maxGOPBytes = 3_000_000
    static let maxPendingWSBytes = 1_500_000

    let port: UInt16
    /// Demande une keyframe à l'encodeur (nouveau client sans GOP en cache, client resynchronisé).
    var onKeyframeNeeded: (() -> Void)?

    private let queue = DispatchQueue(label: "teslamirror.server")
    private var listener: NWListener?
    private var pending: [ObjectIdentifier: NWConnection] = [:]
    private var mjpegClients: [ObjectIdentifier: MJPEGClient] = [:]
    private var wsClients: [ObjectIdentifier: WSClient] = [:]
    /// Clients audio : comptés à part (ni dans maxClients ni dans hasMirrorClients).
    private var audioClients: [ObjectIdentifier: WSClient] = [:]
    private var audioInit: AACEncoder.InitSegment?
    static let maxAudioClients = 4
    static let maxPendingAudioBytes = 200_000

    private var lastJPEG: Data?
    private var initSegment: FMP4Muxer.InitSegment?
    private var gop: [Data] = []
    private var gopBytes = 0
    private var framesSent = 0
    private let startDate = Date()

    // Valeurs lues depuis d'autres threads (pipeline).
    private let lock = NSLock()
    private var _rotation = 0
    private var _mjpegCount = 0
    private var _clientCount = 0
    private var _wsCount = 0
    private var _audioCount = 0

    /// Dossier des fichiers statiques (`Web/`, contenant lib/hls.min.js et lib/mpegts.js).
    var webRoot: URL?
    private lazy var relay: Relay = {
        let relay = Relay(queue: queue)
        relay.headersForURL = { url in
            // Identifiants injectés uniquement vers l'hôte du serveur configuré.
            func sameHost(_ uri: String) -> Bool {
                URL(string: uri)?.host?.lowercased() == url.host?.lowercased()
            }
            var headers: [String: String] = [:]
            if let plex = MediaConfig.plex(), sameHost(plex.uri) { headers.merge(MediaConfig.plexHeaders(plex)) { $1 } }
            if let jf = MediaConfig.jellyfin(), sameHost(jf.uri) { headers.merge(MediaConfig.jellyfinHeaders(jf)) { $1 } }
            return headers
        }
        return relay
    }()

    init(port: UInt16) { self.port = port }

    var rotation: Int {
        get { lock.lock(); defer { lock.unlock() }; return _rotation }
        set { lock.lock(); _rotation = newValue; lock.unlock() }
    }

    var hasMJPEGClients: Bool { lock.lock(); defer { lock.unlock() }; return _mjpegCount > 0 }
    var hasMirrorClients: Bool { lock.lock(); defer { lock.unlock() }; return _wsCount > 0 }
    var hasAudioClients: Bool { lock.lock(); defer { lock.unlock() }; return _audioCount > 0 }

    // MARK: - Cycle de vie

    func start(onFailure: @escaping (Error) -> Void) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw NWError.posix(.EINVAL) }
        let listener = try NWListener(using: params, on: nwPort)
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.stateUpdateHandler = { [weak self] state in
            let text: String
            switch state {
            case .setup: text = "setup"
            case .ready: text = "ready"
            case .waiting(let error): text = "waiting: \(error)"
            case .failed(let error): text = "failed: \(error)"
            case .cancelled: text = "cancelled"
            @unknown default: text = "unknown"
            }
            NSLog("[TeslaMirror] listener port \(nwPort) → \(text)")
            SharedStatus.shared.set("listener", text)
            SharedStatus.shared.set("port", Int(self?.port ?? 0), flush: true)
            if case .failed(let error) = state {
                // Hors de `queue` : le gestionnaire d'erreur peut appeler stop() (queue.sync).
                DispatchQueue.global().async { onFailure(error) }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            relay.cancelAll()
            pending.values.forEach { $0.cancel() }
            mjpegClients.values.forEach { $0.conn.cancel() }
            wsClients.values.forEach { $0.conn.cancel() }
            audioClients.values.forEach { $0.conn.cancel() }
            pending.removeAll(); mjpegClients.removeAll(); wsClients.removeAll(); audioClients.removeAll()
            audioInit = nil
            gop.removeAll(); gopBytes = 0; lastJPEG = nil; initSegment = nil
            updateCounts()
        }
    }

    // MARK: - Publication (appelée depuis les encodeurs)

    func publishJPEG(_ jpeg: Data) {
        queue.async { [self] in
            lastJPEG = jpeg
            for client in mjpegClients.values { sendMJPEGPart(jpeg, to: client) }
        }
    }

    func publishInit(_ segment: FMP4Muxer.InitSegment) {
        queue.async { [self] in
            initSegment = segment
            gop.removeAll(); gopBytes = 0
            for client in wsClients.values {
                sendInit(segment, to: client)
                client.needsKeyframe = true
            }
        }
    }

    func publishAudioInit(_ segment: AACEncoder.InitSegment) {
        queue.async { [self] in
            audioInit = segment
            for client in audioClients.values { sendAudioInit(segment, to: client) }
        }
    }

    func publishAudioFragment(_ fragment: Data) {
        queue.async { [self] in
            // Client lent : on jette (un trou audio vaut mieux qu'un retard qui s'accumule).
            for client in audioClients.values where client.pendingBytes < Self.maxPendingAudioBytes {
                sendWS(opcode: 0x2, payload: fragment, to: client)
            }
        }
    }

    private func sendAudioInit(_ segment: AACEncoder.InitSegment, to client: WSClient) {
        sendWS(opcode: 0x1, payload: Data("{\"type\":\"init\",\"codec\":\"\(segment.codec)\"}".utf8), to: client)
        sendWS(opcode: 0x2, payload: segment.data, to: client)
    }

    func publishFragment(_ fragment: Data, isKeyframe: Bool) {
        queue.async { [self] in
            // Cache du dernier GOP (données encodées uniquement) pour servir un écran statique
            // à un client qui arrive alors que ReplayKit n'envoie plus d'images.
            if isKeyframe {
                gop = [fragment]; gopBytes = fragment.count
            } else if !gop.isEmpty {
                if gopBytes + fragment.count <= Self.maxGOPBytes {
                    gop.append(fragment); gopBytes += fragment.count
                } else {
                    gop.removeAll(); gopBytes = 0
                }
            }
            framesSent += 1
            for client in wsClients.values {
                if client.pendingBytes > Self.maxPendingWSBytes {
                    // Client trop lent : on jette tout jusqu'à la prochaine keyframe.
                    if !client.needsKeyframe { onKeyframeNeeded?() }
                    client.needsKeyframe = true
                    continue
                }
                if client.needsKeyframe && !isKeyframe { continue }
                client.needsKeyframe = false
                sendWS(opcode: 0x2, payload: fragment, to: client)
            }
        }
    }

    // MARK: - Connexions

    private func accept(_ conn: NWConnection) {
        let id = ObjectIdentifier(conn)
        pending[id] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func remove(_ id: ObjectIdentifier) {
        if let c = pending.removeValue(forKey: id) { c.cancel() }
        if let c = mjpegClients.removeValue(forKey: id) { c.conn.cancel() }
        if let c = wsClients.removeValue(forKey: id) { c.conn.cancel() }
        if let c = audioClients.removeValue(forKey: id) { c.conn.cancel() }
        updateCounts()
    }

    private func updateCounts() {
        lock.lock(); _mjpegCount = mjpegClients.count; _clientCount = mjpegClients.count + wsClients.count; _wsCount = wsClients.count; _audioCount = audioClients.count; lock.unlock()
    }

    var clientCountSnapshot: Int { lock.lock(); defer { lock.unlock() }; return _clientCount }

    private var clientCount: Int { mjpegClients.count + wsClients.count }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
                self.route(conn, head: head)
            } else if error != nil || isComplete || buf.count > 16_384 {
                self.remove(ObjectIdentifier(conn))
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func route(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        guard parts.count >= 2, method == "GET" || method == "HEAD" else {
            return respond(conn, status: "405 Method Not Allowed", type: "text/plain", body: Data("405".utf8))
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")

        // Lecteur intégré : relais vers des cibles résolues ici (jamais d'URL libre).
        if path.hasPrefix("/r/") {
            guard let url = relay.verify(path.dropFirst(3)) else {
                return respond(conn, status: "403 Forbidden", type: "text/plain", body: Data("Signature invalide".utf8))
            }
            return relay.start(conn: conn, url: url, method: method, clientHeaders: headers)
        }
        if path.hasPrefix("/plex/") {
            guard let plex = MediaConfig.plex(), let url = URL(string: plex.uri + target.dropFirst(5)) else {
                return respond(conn, status: "404 Not Found", type: "text/plain", body: Data("Plex non configuré dans l'app".utf8))
            }
            return relay.start(conn: conn, url: url, method: method, clientHeaders: headers)
        }
        if path.hasPrefix("/jf/") {
            guard let jf = MediaConfig.jellyfin(), let url = URL(string: jf.uri + target.dropFirst(3)) else {
                return respond(conn, status: "404 Not Found", type: "text/plain", body: Data("Jellyfin non configuré dans l'app".utf8))
            }
            return relay.start(conn: conn, url: url, method: method, clientHeaders: headers)
        }
        if path.hasPrefix("/iptv/") {
            guard let index = Int(path.dropFirst(6)), let url = MediaConfig.iptvURL(index: index) else {
                return respond(conn, status: "404 Not Found", type: "text/plain", body: Data("Chaîne inconnue".utf8))
            }
            return relay.start(conn: conn, url: url, method: method, clientHeaders: headers)
        }
        if path.hasPrefix("/lib/"), let root = webRoot {
            let name = path.dropFirst(5)
            guard !name.contains("/"), !name.contains(".."),
                  let data = try? Data(contentsOf: root.appendingPathComponent("lib").appendingPathComponent(String(name)),
                                       options: .mappedIfSafe) else {
                return respond(conn, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
            }
            return respond(conn, status: "200 OK", type: "application/javascript", body: data, cache: true)
        }

        switch path {
        case "/", "/index.html":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebPages.home.utf8))
        case "/mirror":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebPages.player.utf8))
        case "/mjpeg":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebPages.mjpeg.utf8))
        case "/stream":
            startMJPEG(conn)
        case "/ws":
            guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
                return respond(conn, status: "400 Bad Request", type: "text/plain", body: Data("WebSocket attendu".utf8))
            }
            startWebSocket(conn, key: key)
        case "/wsa":
            guard headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
                return respond(conn, status: "400 Bad Request", type: "text/plain", body: Data("WebSocket attendu".utf8))
            }
            startAudioWebSocket(conn, key: key)
        case "/tv":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: Data(WebPages.tv.utf8))
        case "/api/iptv":
            respond(conn, status: "200 OK", type: "application/json",
                    body: MediaConfig.iptvPublicData() ?? Data(#"{"groups":[],"channels":[]}"#.utf8))
        case "/api/plex":
            let plex = MediaConfig.plex()
            let json = plex.map { #"{"configured":true,"name":"\#($0.name.replacingOccurrences(of: "\"", with: ""))"}"# }
                ?? #"{"configured":false}"#
            respond(conn, status: "200 OK", type: "application/json", body: Data(json.utf8))
        case "/api/jellyfin":
            var obj: [String: Any] = ["configured": false]
            if let jf = MediaConfig.jellyfin() { obj = ["configured": true, "name": jf.name, "userId": jf.userId] }
            respond(conn, status: "200 OK", type: "application/json",
                    body: (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
        case "/health":
            respond(conn, status: "200 OK", type: "text/plain", body: Data("ok".utf8))
        case "/status":
            respond(conn, status: "200 OK", type: "application/json", body: statusJSON())
        case "/favicon.ico":
            respond(conn, status: "204 No Content", type: "image/x-icon", body: Data())
        default:
            respond(conn, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
        }
    }

    private func respond(_ conn: NWConnection, status: String, type: String, body: Data, cache: Bool = false) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + (cache ? "Cache-Control: max-age=86400\r\n" : "Cache-Control: no-store\r\n")
            + "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            self?.remove(ObjectIdentifier(conn))
        })
    }

    private func statusJSON() -> Data {
        var obj: [String: Any] = [
            "rotation": rotation,
            "mjpegClients": mjpegClients.count,
            "wsClients": wsClients.count,
            "audioClients": audioClients.count,
            "audio": audioInit != nil,
            "frames": framesSent,
            "relays": relay.activeJobs,
            "uptime": Int(Date().timeIntervalSince(startDate)),
        ]
        if let s = initSegment {
            obj["codec"] = s.codec; obj["width"] = s.width; obj["height"] = s.height
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    /// Surveille la fermeture côté client (on ne s'intéresse pas aux données reçues).
    private func watchClose(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { self?.remove(ObjectIdentifier(conn)) } else { self?.watchClose(conn) }
        }
    }

    // MARK: - MJPEG

    private final class MJPEGClient {
        let conn: NWConnection
        var busy = false
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private func startMJPEG(_ conn: NWConnection) {
        guard clientCount < Self.maxClients else {
            return respond(conn, status: "503 Service Unavailable", type: "text/plain", body: Data("Trop de clients".utf8))
        }
        let id = ObjectIdentifier(conn)
        pending.removeValue(forKey: id)
        let client = MJPEGClient(conn)
        mjpegClients[id] = client
        updateCounts()
        let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
            + "Cache-Control: no-cache, no-store, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        watchClose(conn)
        if let jpeg = lastJPEG { sendMJPEGPart(jpeg, to: client) }
    }

    private func sendMJPEGPart(_ jpeg: Data, to client: MJPEGClient) {
        guard !client.busy else { return } // client lent : on saute cette image
        client.busy = true
        var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        part.append(jpeg)
        part.append(contentsOf: [0x0D, 0x0A])
        let id = ObjectIdentifier(client.conn)
        client.conn.send(content: part, completion: .contentProcessed { [weak self, weak client] error in
            client?.busy = false
            if error != nil { self?.remove(id) }
        })
    }

    // MARK: - WebSocket

    private final class WSClient {
        let conn: NWConnection
        var pendingBytes = 0
        var needsKeyframe = true
        var inbox: [UInt8] = []
        init(_ conn: NWConnection) { self.conn = conn }
    }

    private func startWebSocket(_ conn: NWConnection, key: String) {
        guard clientCount < Self.maxClients else {
            return respond(conn, status: "503 Service Unavailable", type: "text/plain", body: Data("Trop de clients".utf8))
        }
        let id = ObjectIdentifier(conn)
        pending.removeValue(forKey: id)
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })

        let client = WSClient(conn)
        wsClients[id] = client
        updateCounts()
        readWebSocket(client)

        if let segment = initSegment {
            sendInit(segment, to: client)
            for fragment in gop { sendWS(opcode: 0x2, payload: fragment, to: client) }
            client.needsKeyframe = gop.isEmpty
        }
        if gop.isEmpty { onKeyframeNeeded?() }
    }

    private func startAudioWebSocket(_ conn: NWConnection, key: String) {
        guard audioClients.count < Self.maxAudioClients else {
            return respond(conn, status: "503 Service Unavailable", type: "text/plain", body: Data("Trop de clients".utf8))
        }
        let id = ObjectIdentifier(conn)
        pending.removeValue(forKey: id)
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n"
        conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        let client = WSClient(conn)
        audioClients[id] = client
        updateCounts()
        readWebSocket(client)
        if let segment = audioInit { sendAudioInit(segment, to: client) }
    }

    private func sendInit(_ segment: FMP4Muxer.InitSegment, to client: WSClient) {
        let json = "{\"type\":\"init\",\"codec\":\"\(segment.codec)\",\"width\":\(segment.width),\"height\":\(segment.height)}"
        sendWS(opcode: 0x1, payload: Data(json.utf8), to: client)
        sendWS(opcode: 0x2, payload: segment.data, to: client)
    }

    private func sendWS(opcode: UInt8, payload: Data, to client: WSClient) {
        let frame = Self.wsFrame(opcode: opcode, payload: payload)
        let size = frame.count
        let id = ObjectIdentifier(client.conn)
        client.pendingBytes += size
        client.conn.send(content: frame, completion: .contentProcessed { [weak self, weak client] error in
            client?.pendingBytes -= size
            if error != nil { self?.remove(id) }
        })
    }

    static func wsFrame(opcode: UInt8, payload: Data) -> Data {
        var d = Data(capacity: payload.count + 10)
        d.append(0x80 | opcode)                 // FIN + opcode, pas de masque côté serveur
        let n = payload.count
        if n < 126 {
            d.append(UInt8(n))
        } else if n < 65_536 {
            d.append(126); d.be16(UInt16(n))
        } else {
            d.append(127); d.be64(UInt64(n))
        }
        d.append(payload)
        return d
    }

    private func readWebSocket(_ client: WSClient) {
        client.conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak client] data, _, isComplete, error in
            guard let self, let client else { return }
            let id = ObjectIdentifier(client.conn)
            if let data { client.inbox.append(contentsOf: data) }
            if !self.parseWebSocketFrames(client) || isComplete || error != nil {
                self.remove(id)
            } else {
                self.readWebSocket(client)
            }
        }
    }

    /// Analyse les trames reçues (masquées). Gère close et ping. Retourne false pour fermer.
    private func parseWebSocketFrames(_ client: WSClient) -> Bool {
        while client.inbox.count >= 2 {
            let b = client.inbox
            let opcode = b[0] & 0x0F
            let masked = (b[1] & 0x80) != 0
            var length = Int(b[1] & 0x7F)
            var offset = 2
            if length == 126 {
                guard b.count >= 4 else { return true }
                length = Int(b[2]) << 8 | Int(b[3]); offset = 4
            } else if length == 127 {
                guard b.count >= 10 else { return true }
                var l: UInt64 = 0
                for i in 2..<10 { l = l << 8 | UInt64(b[i]) }
                guard l < 1_000_000 else { return false }
                length = Int(l); offset = 10
            }
            guard length < 1_000_000 else { return false }
            var mask: [UInt8] = [0, 0, 0, 0]
            if masked {
                guard b.count >= offset + 4 else { return true }
                mask = Array(b[offset..<offset + 4]); offset += 4
            }
            guard b.count >= offset + length else { return true }
            var payload = Array(b[offset..<offset + length])
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i & 3] } }
            client.inbox.removeFirst(offset + length)

            switch opcode {
            case 0x8: // close
                let frame = Self.wsFrame(opcode: 0x8, payload: Data(payload.prefix(2)))
                client.conn.send(content: frame, completion: .contentProcessed { _ in })
                return false
            case 0x9: // ping → pong
                sendWS(opcode: 0xA, payload: Data(payload), to: client)
            default:
                break // texte/binaire/pong du client : ignorés
            }
        }
        return true
    }
}
