import Foundation
import Network

/// Serveur de test hébergé par l'APP (pas l'extension), pour isoler les problèmes réseau :
/// si la Tesla atteint ce serveur, le réseau est bon et le problème vient de l'extension.
/// L'app doit rester au premier plan pendant le test (iOS suspend l'app en arrière-plan).
final class TestServer: ObservableObject {
    struct Client: Identifiable {
        let id = UUID()
        let address: String
        let request: String
        let date: Date
    }

    @Published private(set) var state = "arrêté"
    @Published private(set) var running = false
    @Published private(set) var clients: [Client] = []

    let port: UInt16 = 8080
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "teslamirror.testserver")

    func start() {
        stop()
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] st in
                let text: String
                switch st {
                case .setup: text = "setup"
                case .ready: text = "ready (port \(self?.port ?? 0))"
                case .waiting(let e): text = "waiting(\(e))"
                case .failed(let e):
                    if case .posix(let code) = e, code == .EADDRINUSE {
                        text = "failed(port 8080 déjà utilisé — l'extension de diffusion écoute déjà : arrêtez la diffusion pour ce test)"
                    } else {
                        text = "failed(\(e))"
                    }
                case .cancelled: text = "arrêté"
                @unknown default: text = "inconnu"
                }
                DispatchQueue.main.async {
                    self?.state = text
                    if case .failed = st { self?.running = false }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: queue)
            self.listener = listener
            running = true
            state = "démarrage…"
        } catch {
            state = "failed(\(error))"
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        let address: String
        if case .hostPort(let host, let port) = conn.endpoint { address = "\(host):\(port)" } else { address = "\(conn.endpoint)" }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let head = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = head.components(separatedBy: "\r\n").first ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            DispatchQueue.main.async {
                self?.clients.insert(Client(address: address, request: line.isEmpty ? "(connexion sans requête)" : line, date: Date()), at: 0)
                if (self?.clients.count ?? 0) > 30 { self?.clients.removeLast() }
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
