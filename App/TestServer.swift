import Foundation
import Network
import Observation

/// Serveur de test hébergé par l'APP (pas l'extension), pour isoler les problèmes réseau :
/// si la Tesla atteint ce serveur, le réseau est bon et le problème vient de l'extension.
/// L'app doit rester au premier plan pendant le test (iOS suspend l'app en arrière-plan).
@MainActor @Observable
final class TestServer {
    struct Client: Identifiable, Sendable {
        let id = UUID()
        let port: UInt16
        let address: String
        let request: String
        let date: Date
    }

    private(set) var states: [UInt16: String] = [:]
    private(set) var running = false
    private(set) var clients: [Client] = []

    /// Plusieurs ports à la fois : le pare-feu de la voiture peut n'autoriser que 80/443.
    let ports: [UInt16] = [80, 443, 8080, 8000]
    @ObservationIgnored private var listeners: [NWListener] = []
    @ObservationIgnored nonisolated private let queue = DispatchQueue(label: "teslamirror.testserver")

    func start() {
        stop()
        running = true
        for port in ports { listen(on: port) }
    }

    private func listen(on port: UInt16) {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] st in
                let text: String
                switch st {
                case .setup: text = "setup"
                case .ready: text = "ready"
                case .waiting(let e): text = "waiting(\(e))"
                case .failed(let e):
                    if case .posix(let code) = e, code == .EADDRINUSE {
                        text = "failed(port déjà utilisé — arrêtez la diffusion)"
                    } else {
                        text = "failed(\(e))"
                    }
                case .cancelled: text = "arrêté"
                @unknown default: text = "inconnu"
                }
                Task { @MainActor in self?.states[port] = text }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn, port: port) }
            listener.start(queue: queue)
            listeners.append(listener)
            states[port] = "démarrage…"
        } catch {
            states[port] = "failed(\(error))"
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        states.removeAll()
        running = false
    }

    nonisolated private func handle(_ conn: NWConnection, port: UInt16) {
        conn.start(queue: queue)
        let address: String
        if case .hostPort(let host, let port) = conn.endpoint { address = "\(host):\(port)" } else { address = "\(conn.endpoint)" }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = head.components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let client = Client(port: port, address: address, request: line.isEmpty ? "(connexion sans requête)" : line, date: Date())
            Task { @MainActor in
                guard let self else { return }
                self.clients.insert(client, at: 0)
                if self.clients.count > 30 { self.clients.removeLast() }
            }
            let body: String
            let type: String
            if path.hasPrefix("/health") {
                body = "ok"; type = "text/plain"
            } else {
                type = "text/html; charset=utf-8"
                body = """
                <!doctype html><html lang="fr"><head><meta charset="utf-8">
                <meta name="viewport" content="width=device-width,initial-scale=1"><title>TeslaMirror OK</title></head>
                <body style="background:#111;color:#fff;font-family:sans-serif;text-align:center;padding-top:15vh">
                <h1 style="font-size:64px;color:#4caf50">TeslaMirror OK</h1>
                <p style="font-size:24px">Le navigateur atteint bien l'iPhone (serveur de test de l'app).</p>
                <p style="font-size:28px">Port <b>\(port)</b> : ouvert depuis ce navigateur.</p>
                <p style="font-size:20px;color:#aaa">Votre adresse : \(address)</p>
                </body></html>
                """
            }
            let payload = Data(body.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(header.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}
