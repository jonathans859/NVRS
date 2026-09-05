import CryptoKit
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
    private var bytesReceived = 0
    private var linesParsed = 0
    private var decodeFailures = 0
    /// Guards the handshake against being sent twice: the challenge and the
    /// grace timer race each other by design, and whichever loses must do
    /// nothing.
    private var authSent = false

    /// How long to wait for a challenge before assuming the add-on predates it
    /// and falling back to the old handshake. The add-on sends its challenge
    /// before reading anything, so on a healthy link this never elapses.
    private static let challengeGraceSeconds = 2.0

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

    func send(_ message: ClientMessage) {
        queue.async {
            guard let conn = self.connection, case .ready = conn.state else { return }
            self.sendLine(message.jsonObject, on: conn)
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
        authSent = false
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
            emit(.stateChanged(.connected))
            // Listen first: the add-on speaks before we do now, and its
            // challenge decides which handshake we send.
            receiveLoop(on: conn)
            queue.asyncAfter(deadline: .now() + Self.challengeGraceSeconds) { [weak self] in
                guard let self, conn === self.connection, !self.authSent else { return }
                self.sendLegacyAuth(on: conn)
            }
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

    /// Answer the add-on's challenge, so the secret itself never leaves the
    /// phone. `authScheme` is what tells the add-on which of the two this is.
    private func sendChallengeResponse(nonce: String, on conn: NWConnection) {
        guard !authSent else { return }
        authSent = true
        sendLine([
            "auth": Self.authResponse(secret: secret, nonce: nonce),
            "authScheme": WireProtocol.authScheme,
            "protocol": WireProtocol.version,
            "minProtocol": WireProtocol.minimum,
            "client": "NVRS app",
        ], on: conn)
    }

    /// The pre-challenge handshake: the secret in the clear. Only for an add-on
    /// old enough not to challenge us -- it is the thing the challenge exists to
    /// stop, so it must never be what we reach for first.
    private func sendLegacyAuth(on conn: NWConnection) {
        guard !authSent else { return }
        authSent = true
        // The extra keys are additive: an add-on that predates protocol
        // versioning reads "auth" and ignores the rest, so this is safe to send
        // to every add-on already installed.
        sendLine([
            "auth": secret,
            "protocol": WireProtocol.version,
            "minProtocol": WireProtocol.minimum,
            "client": "NVRS app",
        ], on: conn)
    }

    /// Lowercase hex HMAC-SHA256 over the nonce's own characters, keyed with the
    /// secret. Hashing the nonce as sent rather than its decoded bytes keeps the
    /// two ends from having to agree on a hex-decoding step -- a classic way for
    /// peers to quietly derive different keys.
    static func authResponse(secret: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let code = HMAC<SHA256>.authenticationCode(for: Data(nonce.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    /// One NDJSON line up the same socket the add-on streams down.
    private func sendLine(_ object: [String: Any], on conn: NWConnection) {
        guard var payload = try? JSONSerialization.data(withJSONObject: object) else { return }
        payload.append(UInt8(ascii: "\n"))
        conn.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, conn === self.connection else { return }
            if let data, !data.isEmpty {
                self.bytesReceived += data.count
                self.buffer.append(data)
                self.drainLines(on: conn)
                self.emit(.stats(
                    bytesReceived: self.bytesReceived,
                    linesParsed: self.linesParsed,
                    decodeFailures: self.decodeFailures
                ))
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

    private func drainLines(on conn: NWConnection) {
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            guard !lineData.isEmpty else { continue }
            linesParsed += 1
            if let message = WireParser.parse(lineData) {
                if case .challenge(let nonce) = message {
                    // Handshake business, not something the UI has any use for.
                    sendChallengeResponse(nonce: nonce, on: conn)
                    continue
                }
                emit(.message(message))
            } else {
                decodeFailures += 1
            }
        }
    }
}
