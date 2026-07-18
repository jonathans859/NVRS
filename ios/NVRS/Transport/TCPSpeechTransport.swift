import Foundation
import Network

/// Direct TCP connection to the NVDA add-on's listener on the tailnet,
/// speaking NDJSON. Auto-reconnects with exponential backoff until `stop()`.
final class TCPSpeechTransport: SpeechTransport {
    var onEvent: ((TransportEvent) -> Void)?

    private let host: String
    private let port: UInt16
    private let secret: String
    private let queue = DispatchQueue(label: "com.jonathan859.nvrs.transport")
    private var connection: NWConnection?
    private var buffer = Data()
    private var stopped = true
    private var attempt = 0

    init(host: String, port: UInt16, secret: String) {
        self.host = host
        self.port = port
        self.secret = secret
    }

    func start() {
        queue.async {
            self.stopped = false
            self.attempt = 0
            self.openConnection()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.connection?.cancel()
            self.connection = nil
            self.emit(.stateChanged(.idle))
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func emit(_ event: TransportEvent) {
        onEvent?(event)
    }

    private func openConnection() {
        guard !stopped else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            emit(.stateChanged(.disconnected("Invalid port")))
            return
        }
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 10
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 15
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn
        buffer.removeAll()
        emit(.stateChanged(.connecting))
        conn.stateUpdateHandler = { [weak self] state in
            self?.handleState(state, of: conn)
        }
        conn.start(queue: queue)
    }

    private func handleState(_ state: NWConnection.State, of conn: NWConnection) {
        guard conn === connection else { return }
        switch state {
        case .ready:
            attempt = 0
            sendAuth(on: conn)
            emit(.stateChanged(.connected))
            receiveLoop(on: conn)
        case .waiting(let error):
            // No route yet (e.g. Tailscale down); Network.framework retries
            // by itself when connectivity changes, so just surface it.
            emit(.stateChanged(.waiting(error.localizedDescription)))
        case .failed(let error):
            connection = nil
            emit(.stateChanged(.disconnected(error.localizedDescription)))
            scheduleReconnect()
        case .cancelled:
            if !stopped {
                // Cancelled by us after a server-side close; reconnect.
                connection = nil
                scheduleReconnect()
            }
        default:
            break
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        attempt += 1
        let delay = min(60.0, pow(2.0, Double(min(attempt, 6)))) + Double.random(in: 0...1)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.connection == nil else { return }
            self.openConnection()
        }
    }

    private func sendAuth(on conn: NWConnection) {
        guard
            let payload = try? JSONSerialization.data(withJSONObject: ["auth": secret]),
            var line = String(data: payload, encoding: .utf8)
        else { return }
        line.append("\n")
        conn.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                // Server closed (bad auth, NVDA exiting) or the link died.
                self.emit(.stateChanged(.disconnected(error?.localizedDescription ?? "Connection closed by PC")))
                conn.cancel()
            } else {
                self.receiveLoop(on: conn)
            }
        }
    }

    private func drainLines() {
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            if let message = WireParser.parse(lineData) {
                emit(.message(message))
            }
        }
    }
}
