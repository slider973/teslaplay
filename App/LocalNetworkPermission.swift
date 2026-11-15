import Foundation
import Network
import dnssd

/// Déclenche la demande d'autorisation « Réseau local » depuis l'app (iOS ne la propose
/// qu'à une app qui publie ou cherche un service Bonjour déclaré dans NSBonjourServices),
/// puis détermine si elle est accordée : le navigateur Bonjour retrouve notre propre service
/// si l'accès est autorisé, ou passe en `.waiting(PolicyDenied)` s'il est refusé.
final class LocalNetworkPermission: ObservableObject {
    enum State: Equatable { case unknown, checking, granted, denied }

    static let serviceType = "_teslamirror._tcp"

    @Published private(set) var state: State = .unknown
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let serviceName = "TeslaMirror-" + UUID().uuidString.prefix(8)

    func request() {
        guard state != .checking else { return }
        stop()
        state = .checking

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        do {
            let listener = try NWListener(using: params) // port libre quelconque
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.finish(.denied) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("[TeslaMirror] NWListener Bonjour: \(error)")
        }

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state, case .dns(let code) = error,
               code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                self?.finish(.denied)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let found = results.contains { result in
                if case .service(let name, _, _, _) = result.endpoint { return name == self.serviceName }
                return false
            }
            if found { self.finish(.granted) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func finish(_ result: State) {
        guard state == .checking else { return }
        state = result
        stop()
    }

    private func stop() {
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
    }
}
