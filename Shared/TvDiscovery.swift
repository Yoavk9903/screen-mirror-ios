import Foundation
import Network

struct DiscoveredTv: Identifiable, Hashable {
    let id: String   // service name, unique per TV
    let name: String
    let host: String
    let port: Int
}

/// Finds ScreenMirrorReceiver instances on the LAN via Bonjour (the same
/// "_screenmirror._tcp" service the Android TV app advertises via NsdAdvertiser.kt —
/// Bonjour and Android's NSD are both just mDNS/DNS-SD under the hood, so no changes
/// are needed on the TV side).
final class TvDiscovery: ObservableObject {
    @Published private(set) var tvs: [DiscoveredTv] = []

    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_screenmirror._tcp", domain: nil), using: params)
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                self.resolve(result: result, name: name)
            }
            let currentNames = Set(results.compactMap { result -> String? in
                if case let .service(name, _, _, _) = result.endpoint { return name }
                return nil
            })
            self.tvs.removeAll { !currentNames.contains($0.id) }
        }

        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
        tvs.removeAll()
    }

    private func resolve(result: NWBrowser.Result, name: String) {
        if resolvers[name] != nil { return }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        resolvers[name] = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, let path = connection.currentPath,
               let endpoint = path.remoteEndpoint,
               case let .hostPort(host, port) = endpoint {
                let hostString = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                let tv = DiscoveredTv(id: name, name: name, host: hostString, port: Int(port.rawValue))
                DispatchQueue.main.async {
                    if !self.tvs.contains(where: { $0.id == tv.id }) {
                        self.tvs.append(tv)
                    }
                }
                connection.cancel()
                self.resolvers[name] = nil
            }
        }
        connection.start(queue: .main)
    }
}
