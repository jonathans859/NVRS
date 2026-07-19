import Foundation

enum TransportState: Equatable {
    case idle
    case connecting
    case connected
    case waiting(String)
    case disconnected(String?)
}

enum TransportEvent {
    case stateChanged(TransportState)
    case message(ServerMessage)
    /// Low-level receive counters for diagnosing where a silent stream dies.
    case stats(bytesReceived: Int, linesParsed: Int, decodeFailures: Int)
}

/// Abstraction over how NVRS messages reach the app, so a relay transport
/// (e.g. WSS via a VPS) can be added later without touching the rest of
/// the app. v1 ships `TCPSpeechTransport` (direct over Tailscale).
protocol SpeechTransport: AnyObject {
    /// Called on an arbitrary queue; hop to the main actor before touching UI state.
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func start()
    func stop()
}
