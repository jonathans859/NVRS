import Combine
import Foundation
import UIKit

@MainActor
final class MirrorViewModel: ObservableObject {
    @Published private(set) var connectionState: TransportState = .idle
    @Published private(set) var lastSpoken: String = ""
    @Published private(set) var pcSynthDescription: String?
    @Published var isConnectEnabled = false
    @Published var isLocalSpeechMuted = false

    // Diagnostics
    @Published private(set) var envelopesReceived = 0
    @Published private(set) var utterancesStarted = 0
    @Published private(set) var audioError: String?
    @Published private(set) var bytesReceived = 0
    @Published private(set) var linesParsed = 0
    @Published private(set) var decodeFailures = 0

    let settings: SettingsStore
    private let renderer = SpeechRenderer()
    private let audioSession = AudioSessionController()
    private let filterEngine = NotificationFilterEngine()
    private var transport: SpeechTransport?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore) {
        self.settings = settings
        renderer.onActivity = { [weak self] active in
            guard let self else { return }
            if active {
                self.audioSession.speechActivity()
            } else {
                self.audioSession.rendererBecameIdle()
            }
        }
        audioSession.isRendererIdle = { [weak self] in
            self?.renderer.isIdle ?? true
        }
        renderer.onUtteranceStarted = { [weak self] in
            self?.utterancesStarted += 1
        }
        // A connection that died while suspended shows up as failed only
        // after backoff; on return to foreground, reconnect right away.
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconnectAfterForeground()
            }
        }
        applyBaselines()
        filterEngine.filters = settings.filters
        // React to settings changes: update baselines/filters live.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyBaselines()
                    self.filterEngine.filters = self.settings.filters
                }
            }
            .store(in: &cancellables)
        if settings.autoConnect, !settings.host.isEmpty {
            connect()
        }
    }

    private func applyBaselines() {
        renderer.baseVoiceIdentifier = settings.voiceIdentifier
        renderer.baseRate = Float(settings.baseRate)
        renderer.basePitch = Float(settings.basePitch)
        renderer.baseVolume = Float(settings.baseVolume)
    }

    // MARK: - Connection control

    func connect() {
        disconnectTransportOnly()
        guard !settings.host.isEmpty, settings.port > 0, settings.port <= 65535 else {
            connectionState = .disconnected("Host and port are not configured")
            return
        }
        let tcp = TCPSpeechTransport(
            host: settings.host,
            port: UInt16(settings.port),
            secret: settings.secret
        )
        tcp.onEvent = { [weak self, weak tcp] event in
            DispatchQueue.main.async {
                guard let self, let tcp, tcp === self.transport as? TCPSpeechTransport else {
                    // A replaced transport's trailing events must not
                    // clobber the live connection's state.
                    return
                }
                self.handle(event)
            }
        }
        transport = tcp
        isConnectEnabled = true
        tcp.start()
    }

    func disconnect() {
        isConnectEnabled = false
        disconnectTransportOnly()
        renderer.cancelAll()
        audioSession.shutdown()
        connectionState = .idle
    }

    private func disconnectTransportOnly() {
        transport?.stop()
        transport = nil
    }

    private func reconnectAfterForeground() {
        guard isConnectEnabled, connectionState != .connected else { return }
        connect()
    }

    /// Speaks a canned phrase through the exact same renderer/audio path as
    /// mirrored speech — separates audio problems from transport problems.
    func speakTest() {
        audioSession.speechActivity()
        audioError = audioSession.lastError
        let envelope = SpeechEnvelope(
            seq: 0,
            priority: .now,
            ts: 0,
            items: [.text("NVRS test. Speech on this iPhone is working.")]
        )
        renderer.enqueue(envelope)
    }

    /// Magic-tap target: mute/unmute local playback without dropping the link.
    func toggleLocalMute() {
        isLocalSpeechMuted.toggle()
        if isLocalSpeechMuted {
            renderer.cancelAll()
        }
        UIAccessibility.post(
            notification: .announcement,
            argument: isLocalSpeechMuted
                ? String(localized: "NVRS speech off")
                : String(localized: "NVRS speech on")
        )
    }

    // MARK: - Event handling

    private func handle(_ event: TransportEvent) {
        switch event {
        case .stateChanged(let state):
            let wasConnected = connectionState == .connected
            connectionState = state
            if state == .connected {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "NVRS connected")
                )
            } else if wasConnected {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: String(localized: "NVRS connection lost")
                )
            }
        case .message(let message):
            handle(message)
        case .stats(let bytes, let lines, let failures):
            bytesReceived = bytes
            linesParsed = lines
            decodeFailures = failures
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .speech(let envelope):
            envelopesReceived += 1
            let text = envelope.plainText
            if !text.isEmpty {
                lastSpoken = text
            }
            filterEngine.process(text)
            if !isLocalSpeechMuted {
                audioSession.speechActivity()
                audioError = audioSession.lastError
                renderer.enqueue(envelope)
            }
        case .cancel:
            renderer.cancelAll()
        case .beep(let hz, let ms, let left, let right):
            if !isLocalSpeechMuted {
                audioSession.speechActivity()
                renderer.playImmediateBeep(hz: hz, ms: ms, pan: Float((right - left) / 100.0))
            }
        case .synthConfig(let config):
            // Informational in v1: offsets are applied to the local baseline.
            pcSynthDescription = config.voiceName ?? config.synth
        case .unknown:
            break
        }
    }

    // MARK: - Status text

    var statusSentence: String {
        switch connectionState {
        case .idle:
            return String(localized: "Not connected.")
        case .connecting:
            return String(localized: "Connecting to \(settings.host)…")
        case .connected:
            if let pcSynthDescription {
                return String(localized: "Connected to \(settings.host). PC voice: \(pcSynthDescription).")
            }
            return String(localized: "Connected to \(settings.host).")
        case .waiting(let reason):
            return String(localized: "Waiting for network: \(reason)")
        case .disconnected(let reason):
            if let reason {
                return String(localized: "Disconnected: \(reason). Retrying automatically.")
            }
            return String(localized: "Disconnected. Retrying automatically.")
        }
    }
}
