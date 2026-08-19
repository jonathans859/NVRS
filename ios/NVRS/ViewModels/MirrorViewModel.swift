import AVFoundation
import Combine
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// One mirrored line. Carries an identity so the list keeps its place
/// while new speech arrives at the top.
struct SpokenLine: Identifiable {
    let id = UUID()
    let text: String
}

@MainActor
final class MirrorViewModel: ObservableObject {
    @Published private(set) var connectionState: TransportState = .idle
    /// Everything mirrored so far, newest first, capped at the user's limit.
    @Published private(set) var speechLog: [SpokenLine] = []
    @Published private(set) var pcSynthDescription: String?
    @Published private(set) var pcConfig: SynthConfig?
    @Published var isConnectEnabled = false
    @Published var isLocalSpeechMuted = false
    /// The PC's own speakers, as last reported by the add-on. `pcMuteAllowed`
    /// mirrors the opt-in checkbox in NVDA's NVRS settings — without it the
    /// PC ignores mute requests, so the control stays hidden.
    @Published private(set) var isPCAudioMuted = false
    @Published private(set) var pcMuteAllowed = false
    /// NVDA's speech is paused (shift key on the PC).
    @Published private(set) var isSpeechPaused = false

    // Diagnostics
    @Published private(set) var envelopesReceived = 0
    @Published private(set) var utterancesStarted = 0
    @Published private(set) var audioError: String?
    @Published private(set) var bytesReceived = 0
    @Published private(set) var linesParsed = 0
    @Published private(set) var decodeFailures = 0
    /// Pause-shortening spike: last offline-render report, newest first line.
    @Published private(set) var probeReport: [String] = []
    @Published private(set) var isProbing = false
    /// Times the audio graph was torn down mid-speech and the speech it was
    /// playing had to be queued again.
    @Published private(set) var audioResets = 0
    /// Keystroke cancels held back so fast typing queues instead of
    /// swallowing itself.
    @Published private(set) var typingCancelsHeld = 0
    /// Utterances that fell back to plain speak() because the render failed.
    @Published private(set) var trimFallbacks = 0
    @Published private(set) var lastTrimFailure: String?
    /// The fallbacks split by cause. A hung render is heard as a stall; a
    /// voice returning nothing is not. One timeout used to drag several of
    /// the latter behind it, so the two counts climbing together is the
    /// signature of a cascade rather than of independent failures.
    @Published private(set) var trimTimeouts = 0
    @Published private(set) var trimEmptyRenders = 0
    /// What a *healthy* render costs. Failures are excluded on purpose: a
    /// timeout is pinned to the watchdog rather than to the voice, so
    /// leaving it in hides the slowest render that actually succeeded -
    /// which is the number a length-scaled timeout has to be sized against.
    @Published private(set) var successfulRenders = 0
    @Published private(set) var averageRenderSeconds = 0.0
    @Published private(set) var slowestRenderSeconds = 0.0
    /// Length of that slowest successful render, so its cost can be read
    /// against the size of the text instead of guessed at.
    @Published private(set) var slowestRenderCharacters = 0
    /// How long the renderer had been quiet before the last render that
    /// hung. A cold re-warm predicts a long gap here; anything else
    /// predicts a short one — which is the whole point of recording it.
    @Published private(set) var lastTimeoutIdleSeconds: Double?
    /// Length of the utterance that hung. A long one points at the flat
    /// timeout cutting off honest work; a short one points at a real stall.
    @Published private(set) var lastTimeoutCharacters: Int?
    /// Utterances too long to render, spoken the plain way instead. Says
    /// how much text is losing pause shortening to the length limit.
    @Published private(set) var longUtterancesSpokenPlain = 0
    @Published private(set) var longestPlainCharacters = 0
    private var totalRenderSeconds = 0.0
    private var probeToken = 0

    /// The diagnostics section as plain lines. One source for both the
    /// display and the copy button, so what lands in a bug report is
    /// exactly what was on screen — the probe report does the same.
    var diagnosticLines: [String] {
        var lines = [
            "Bytes \(bytesReceived), lines \(linesParsed), bad \(decodeFailures), received \(envelopesReceived), spoken \(utterancesStarted).",
        ]
        if let audioError {
            lines.append("Audio session error: \(audioError)")
        }
        if audioResets > 0 {
            lines.append("Audio graph reset \(audioResets) times; the speech it was playing was queued again.")
        }
        if typingCancelsHeld > 0 {
            lines.append("Queued \(typingCancelsHeld) keystroke echoes instead of cutting them off.")
        }
        if trimFallbacks > 0 {
            lines.append("Pause shortening fell back \(trimFallbacks) times. Last reason: \(lastTrimFailure ?? "unknown").")
            lines.append("Of the failed renders, \(trimTimeouts) hung and \(trimEmptyRenders) came back empty.")
            var hung: [String] = []
            if let idle = lastTimeoutIdleSeconds {
                hung.append(String(format: "quiet for %.1f s", idle))
            }
            if let characters = lastTimeoutCharacters {
                hung.append("\(characters) characters")
            }
            if !hung.isEmpty {
                lines.append("Before the last one hung: \(hung.joined(separator: ", ")).")
            }
        }
        if longUtterancesSpokenPlain > 0 {
            lines.append("Spoke \(longUtterancesSpokenPlain) utterances the plain way for being too long (longest \(longestPlainCharacters) characters).")
        }
        if successfulRenders > 0 {
            let average = String(format: "%.0f", averageRenderSeconds * 1000)
            let slowest = String(format: "%.0f", slowestRenderSeconds * 1000)
            lines.append("Render \(average) ms average, \(slowest) ms slowest (\(slowestRenderCharacters) characters), over \(successfulRenders) successful renders.")
        }
        return lines
    }

    let settings: SettingsStore
    /// One engine for beeps, mirrored speech and the probe alike.
    private let audioHost: AudioEngineHost
    private let renderer: SpeechRenderer
    private let renderProbe: OfflineRenderProbe
    private let soundPlayer = SoundPlayer()
    private let audioSession = AudioSessionController()
    private var transport: SpeechTransport?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore) {
        // Built locally: stored properties can't be read until every one of
        // them has a value.
        let host = AudioEngineHost()
        self.settings = settings
        audioHost = host
        renderer = SpeechRenderer(host: host)
        renderProbe = OfflineRenderProbe(host: host)
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
        audioSession.startSilentEngine = { [weak self] in
            self?.renderer.startAudioKeepAlive()
        }
        audioSession.stopSilentEngine = { [weak self] in
            self?.renderer.stopAudioKeepAlive()
        }
        renderer.onUtteranceStarted = { [weak self] in
            self?.utterancesStarted += 1
        }
        renderer.onTrimFailure = { [weak self] reason in
            self?.trimFallbacks += 1
            self?.lastTrimFailure = reason
        }
        renderer.onRenderOutcome = { [weak self] outcome in
            guard let self else { return }
            if outcome.timedOut {
                self.trimTimeouts += 1
                self.lastTimeoutIdleSeconds = outcome.idleSeconds
                self.lastTimeoutCharacters = outcome.characterCount
                return
            }
            if outcome.failure != nil {
                self.trimEmptyRenders += 1
                return
            }
            self.successfulRenders += 1
            self.totalRenderSeconds += outcome.renderSeconds
            self.averageRenderSeconds = self.totalRenderSeconds / Double(self.successfulRenders)
            if outcome.renderSeconds > self.slowestRenderSeconds {
                self.slowestRenderSeconds = outcome.renderSeconds
                self.slowestRenderCharacters = outcome.characterCount
            }
        }
        renderer.onLongUtteranceSpokenPlain = { [weak self] characters in
            guard let self else { return }
            self.longUtterancesSpokenPlain += 1
            self.longestPlainCharacters = max(self.longestPlainCharacters, characters)
        }
        renderer.onAudioReset = { [weak self] in
            self?.audioResets += 1
        }
        renderer.onTypingCancelHeld = { [weak self] in
            self?.typingCancelsHeld += 1
        }
        // A connection that died while the app couldn't run shows up as
        // failed only after backoff; reconnect right away instead when the
        // app returns to the foreground (iOS) or the Mac wakes from sleep.
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconnectAfterForeground()
            }
        }
        #elseif os(macOS)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconnectAfterForeground()
            }
        }
        #endif
        applyBaselines()
        // React to settings changes: update baselines live.
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyBaselines()
                    self.trimSpeechLog()
                    self.audioSession.setKeepAliveWanted(
                        self.settings.keepAliveInBackground && self.isConnectEnabled
                    )
                }
            }
            .store(in: &cancellables)
        if settings.autoConnect, !settings.host.isEmpty {
            connect()
        }
    }

    private func applyBaselines() {
        renderer.baseVoiceIdentifier = effectiveVoiceIdentifier()
        renderer.baseRate = effectiveRate()
        renderer.basePitch = Float(settings.basePitch)
        renderer.baseVolume = Float(settings.baseVolume)
        // Assigning the mode re-arms trimming after it disabled itself on a
        // voice that won't render, so touching any setting is the way back.
        renderer.pauseMode = settings.pauseMode
        renderer.pauseFactor = settings.pauseFactor
        renderer.trimCharacterLimit = settings.pauseCharacterLimit
    }

    /// The phone voice, honoring "follow PC voice": an explicit mapping
    /// wins; otherwise auto-pick a same-language sibling of the user's
    /// chosen voice (PC English Eloquence → phone English Eloquence).
    private func effectiveVoiceIdentifier() -> String? {
        guard settings.followPCVoice, let config = pcConfig else {
            return settings.voiceIdentifier
        }
        let key = Self.pcVoiceKey(for: config)
        if let mapped = settings.pcVoices.first(where: { $0.key == key })?.phoneVoiceId {
            return mapped
        }
        if let lang = config.lang, let auto = Self.autoVoice(
            forPCLang: lang,
            near: settings.voiceIdentifier
        ) {
            return auto
        }
        return settings.voiceIdentifier
    }

    private func effectiveRate() -> Float {
        if settings.followPCRate, let rate = pcConfig?.rate {
            // NVDA's 0–100 onto AVSpeech's 0–1 (default 0.5 = NVDA 50).
            return min(max(Float(rate) / 100.0, 0.05), 1.0)
        }
        return Float(settings.baseRate)
    }

    static func pcVoiceKey(for config: SynthConfig) -> String {
        "\(config.synth)|\(config.voice ?? "")"
    }

    /// Same persona in the target language if available (Apple Eloquence
    /// personas exist per language), then same engine family, then any
    /// voice of that language.
    static func autoVoice(forPCLang lang: String, near currentId: String?) -> String? {
        let bcp47 = lang.replacingOccurrences(of: "_", with: "-")
        let primary = bcp47.prefix(2)
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language == bcp47 || $0.language.prefix(2) == primary
        }
        guard !candidates.isEmpty else { return nil }
        let exact = candidates.filter { $0.language == bcp47 }
        let pool = exact.isEmpty ? candidates : exact
        if let currentId, let current = AVSpeechSynthesisVoice(identifier: currentId) {
            if current.language.prefix(2) == primary {
                return currentId // already speaking that language
            }
            if let samePersona = pool.first(where: { $0.name == current.name }) {
                return samePersona.identifier
            }
            let family = currentId.split(separator: ".").dropLast(2).joined(separator: ".")
            if !family.isEmpty, let sameFamily = pool.first(where: { $0.identifier.hasPrefix(family) }) {
                return sameFamily.identifier
            }
        }
        return AVSpeechSynthesisVoice(language: bcp47)?.identifier ?? pool.first?.identifier
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
        audioSession.setKeepAliveWanted(settings.keepAliveInBackground)
    }

    func disconnect() {
        isConnectEnabled = false
        disconnectTransportOnly()
        renderer.cancelAll()
        audioSession.shutdown()
        connectionState = .idle
        // Dropping the link is what unmutes the PC, so don't keep showing
        // a control for a mute that no longer exists.
        isPCAudioMuted = false
        pcMuteAllowed = false
        // The connect button carries no spoken value, and .idle produces no
        // state event, so the announcement is the only confirmation.
        Announce.post(String(localized: "NVRS disconnected"))
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
        #if os(macOS)
        let phrase = "NVRS test. Speech on this Mac is working."
        #else
        let phrase = "NVRS test. Speech on this iPhone is working."
        #endif
        let envelope = SpeechEnvelope(
            seq: 0,
            priority: .now,
            ts: 0,
            items: [.text(phrase)]
        )
        renderer.enqueue(envelope)
    }

    /// Pause-shortening spike: renders the probe phrase with the voice that
    /// mirrored speech would use, through `write(_:toBufferCallback:)`
    /// instead of `speak()`. `play` additionally schedules the result on our
    /// own engine, unmodified — the two halves of the question ("does this
    /// voice render offline" and "can we play what it gives us") stay
    /// separately answerable.
    func runRenderProbe(mode: PauseMode, silent: Bool) {
        guard !isProbing else { return }
        beginProbe(String(localized: "Rendering…"))
        if !silent {
            audioSession.speechActivity()
            audioError = audioSession.lastError
        }
        let voice = effectiveVoiceIdentifier().flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        renderProbe.run(
            voice: voice,
            rate: effectiveRate(),
            pitch: Float(settings.basePitch),
            volume: Float(settings.baseVolume),
            mode: mode,
            factor: settings.pauseFactor,
            silent: silent
        ) { [weak self] report in
            self?.endProbe(report)
        }
    }

    /// Spells a word through the trimmed path and reports the gaps between
    /// letters — the case where the phone used to lag far behind Windows.
    func runSpellProbe(mode: PauseMode) {
        guard !isProbing else { return }
        beginProbe(String(localized: "Spelling…"))
        audioSession.speechActivity()
        audioError = audioSession.lastError
        let voice = effectiveVoiceIdentifier().flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        renderProbe.spell(
            voice: voice,
            rate: effectiveRate(),
            pitch: Float(settings.basePitch),
            volume: Float(settings.baseVolume),
            mode: mode,
            factor: settings.pauseFactor
        ) { [weak self] report in
            self?.endProbe(report)
        }
    }

    /// A probe that never reports back would leave its buttons disabled for
    /// good, so every run carries a deadline.
    private func beginProbe(_ status: String) {
        isProbing = true
        probeReport = [status]
        probeToken += 1
        let token = probeToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.isProbing, token == self.probeToken else { return }
            self.isProbing = false
            self.probeReport = [String(localized: "The probe did not report back within 20 seconds.")]
            Announce.post(String(localized: "Probe timed out"))
        }
    }

    private func endProbe(_ report: OfflineRenderProbe.Report) {
        probeToken += 1
        isProbing = false
        probeReport = report.lines
        Announce.post(report.headline)
    }

    /// Magic-tap target: mute/unmute local playback without dropping the link.
    func toggleLocalMute() {
        isLocalSpeechMuted.toggle()
        if isLocalSpeechMuted {
            renderer.cancelAll()
        }
        Announce.post(
            isLocalSpeechMuted
                ? String(localized: "NVRS speech off")
                : String(localized: "NVRS speech on")
        )
    }

    /// Asks the PC to mute or unmute its own speakers. The add-on echoes the
    /// result back, which is what finally sets `isPCAudioMuted`; the
    /// optimistic update here just keeps the toggle from snapping back
    /// during the round trip.
    func setPCAudioMuted(_ muted: Bool) {
        guard pcMuteAllowed else { return }
        isPCAudioMuted = muted
        transport?.send(.setPCMute(muted))
    }

    // MARK: - Event handling

    private func handle(_ event: TransportEvent) {
        switch event {
        case .stateChanged(let state):
            let wasConnected = connectionState == .connected
            connectionState = state
            if state == .connected {
                Announce.post(String(localized: "NVRS connected"))
            } else if wasConnected {
                Announce.post(String(localized: "NVRS connection lost"))
            }
            if state != .connected {
                isSpeechPaused = false
                // The PC unmutes itself the moment we drop off, so the
                // control must not linger showing a stale mute.
                isPCAudioMuted = false
                pcMuteAllowed = false
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
                appendToLog(text)
            }
            if !isLocalSpeechMuted {
                audioSession.speechActivity()
                audioError = audioSession.lastError
                renderer.enqueue(envelope)
            }
        case .cancel:
            isSpeechPaused = false
            renderer.remoteCancel()
        case .pause(let paused):
            // Mirrors NVDA's shift key. Shown in the UI because a phone that
            // has gone quiet on purpose looks exactly like one that has
            // broken.
            isSpeechPaused = paused
            renderer.setPaused(paused)
        case .beep(let hz, let ms, let left, let right):
            if !isLocalSpeechMuted {
                audioSession.speechActivity()
                renderer.playImmediateBeep(hz: hz, ms: ms, pan: Float((right - left) / 100.0))
            }
        case .wave(let name):
            if !isLocalSpeechMuted {
                audioSession.speechActivity()
                soundPlayer.play(name)
            }
        case .pcMute(let muted, let allowed):
            let changed = muted != isPCAudioMuted
            isPCAudioMuted = muted
            pcMuteAllowed = allowed
            if changed {
                // Covers the PC-side shortcut too, so the phone always
                // says which end is talking.
                Announce.post(
                    muted
                        ? String(localized: "PC speech off")
                        : String(localized: "PC speech on")
                )
            }
        case .synthConfig(let config):
            pcConfig = config
            pcSynthDescription = config.voiceName ?? config.synth
            recordPCVoice(config)
            // Re-derive voice/rate in case "follow PC" settings are on.
            applyBaselines()
        case .unknown:
            break
        }
    }

    private func appendToLog(_ text: String) {
        speechLog.insert(SpokenLine(text: text), at: 0)
        trimSpeechLog()
    }

    /// Also runs when the limit setting changes, so lowering it takes
    /// effect on what is already on screen.
    private func trimSpeechLog() {
        let limit = max(1, settings.speechLogLimit)
        if speechLog.count > limit {
            speechLog.removeLast(speechLog.count - limit)
        }
    }

    private func recordPCVoice(_ config: SynthConfig) {
        let key = Self.pcVoiceKey(for: config)
        guard !settings.pcVoices.contains(where: { $0.key == key }) else { return }
        let label = "\(config.voiceName ?? config.voice ?? "?") (\(config.synth))"
        settings.pcVoices.append(
            PCVoice(key: key, label: label, lang: config.lang, phoneVoiceId: nil)
        )
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
