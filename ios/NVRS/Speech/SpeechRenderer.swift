import AVFoundation
import Foundation

/// Reconstructs NVDA speech sequences with AVSpeechSynthesizer.
///
/// NVDA prosody commands are relative (offset on a 0–100 scale, or a
/// multiplier); they are applied on top of the *local* baseline from
/// Settings, so emphasis cues survive while the phone keeps its own
/// comfortable voice/rate.
final class SpeechRenderer: NSObject, AVSpeechSynthesizerDelegate {
    /// One queued unit of playback.
    private enum Step {
        case utterance(AVSpeechUtterance)
        case beep(hz: Double, ms: Double, pan: Float)
    }

    private struct ProsodyState {
        var pitch: (offset: Int, multiplier: Double?) = (0, nil)
        var rate: (offset: Int, multiplier: Double?) = (0, nil)
        var volume: (offset: Int, multiplier: Double?) = (0, nil)
        var lang: String?
        var characterMode = false
    }

    private let synthesizer = AVSpeechSynthesizer()
    private let beepPlayer: BeepPlayer
    private let trimmedPlayer: TrimmedUtterancePlayer
    private var pending: [Step] = []
    private var speaking = false
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]
    /// Consecutive failed renders. A voice that can't be rendered offline
    /// must not cost every utterance a failed attempt, so trimming switches
    /// itself off until the user changes the setting again.
    private var trimFailureStreak = 0
    private var trimDisabled = false
    private var trimRearm: DispatchWorkItem?
    private var isPaused = false
    /// The last utterance handed to a player was a keystroke echo.
    private var lastEnqueuedBrief = false
    /// A keystroke echo: one or two characters, as typing produces.
    private let briefCharacterLimit = 3
    /// How far behind the PC we are willing to fall before letting a
    /// keystroke cancel do its job again.
    private let maxTypingBacklog = 6

    /// Baselines, updated from Settings. Read on the main thread.
    var baseVoiceIdentifier: String?
    var baseRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var basePitch: Float = 1.0
    var baseVolume: Float = 1.0

    /// Called whenever the renderer starts or stops having work; drives
    /// audio session activation/idle handling.
    var onActivity: ((Bool) -> Void)?

    /// Called (on main) each time the synthesizer actually starts an
    /// utterance; drives the diagnostics counter.
    var onUtteranceStarted: (() -> Void)?

    /// Reports a failed offline render, with the reason. The utterance is
    /// still spoken — this is for the diagnostics line, not for the user.
    var onTrimFailure: ((String) -> Void)?

    /// Every render's cost and result, success or failure. Diagnostics only.
    var onRenderOutcome: ((TrimmedUtterancePlayer.Outcome) -> Void)?

    /// A keystroke cancel was held back so the letters could queue instead
    /// of swallowing each other. Diagnostics only.
    var onTypingCancelHeld: (() -> Void)?

    /// The audio graph was torn down mid-speech and what it was playing had
    /// to be queued again. Diagnostics only; recovery is automatic.
    var onAudioReset: (() -> Void)?

    /// Pause shortening. `.off` keeps the plain `speak()` path, so the
    /// default behaviour is byte-for-byte what it was.
    var pauseMode: PauseMode = .off {
        didSet {
            trimmedPlayer.mode = pauseMode
            trimFailureStreak = 0
            trimDisabled = false
            trimRearm?.cancel()
        }
    }

    var pauseFactor: Double = 0.3 {
        didSet { trimmedPlayer.factor = pauseFactor }
    }

    private var trimmingActive: Bool {
        pauseMode != .off && !trimDisabled
    }

    init(host: AudioEngineHost) {
        beepPlayer = BeepPlayer(host: host)
        trimmedPlayer = TrimmedUtterancePlayer(host: host)
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        synthesizer.usesApplicationAudioSession = true
        #endif
        trimmedPlayer.onStarted = { [weak self] in
            self?.onUtteranceStarted?()
        }
        trimmedPlayer.onProgress = { [weak self] in
            self?.speakNextIfIdle()
        }
        trimmedPlayer.onOutcome = { [weak self] outcome in
            if outcome.failure == nil {
                self?.trimFailureStreak = 0
            }
            self?.onRenderOutcome?(outcome)
        }
        trimmedPlayer.onFailure = { [weak self] reason, returned in
            self?.handleTrimFailure(reason, returned: returned)
        }
        trimmedPlayer.onAudioReset = { [weak self] lost in
            self?.recoverFromAudioReset(lost)
        }
    }

    // MARK: - Public API (main thread)

    func enqueue(_ envelope: SpeechEnvelope) {
        let steps = buildSteps(from: envelope)
        guard !steps.isEmpty else { return }
        switch envelope.priority {
        case .now:
            // Interrupt: this is what makes it feel live instead of laggy.
            pending = steps
            interruptCurrentUtterance()
        case .next:
            pending.insert(contentsOf: steps, at: 0)
        case .normal:
            pending.append(contentsOf: steps)
        }
        speakNextIfIdle()
    }

    /// Plays a standalone beep right away, bypassing the speech queue —
    /// mirrors NVDA's asynchronous tones.beep.
    func playImmediateBeep(hz: Double, ms: Double, pan: Float) {
        beepPlayer.play(hz: hz, ms: ms, pan: pan)
    }

    /// Background keep-alive: the beep engine renders silence while running.
    func startAudioKeepAlive() {
        beepPlayer.startKeepAlive()
    }

    func stopAudioKeepAlive() {
        // One shared engine now, so stopping it would cut speech off mid-word.
        guard trimmedPlayer.isIdle else { return }
        beepPlayer.stopKeepAlive()
    }

    /// NVDA's shift-key pause, mirrored. Both paths can hold and resume:
    /// the system synthesizer has its own pause, and our player node keeps
    /// its scheduled audio and picks up where it stopped.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        trimmedPlayer.setPaused(paused)
        if paused {
            if synthesizer.isSpeaking, !synthesizer.isPaused {
                synthesizer.pauseSpeaking(at: .word)
            }
        } else {
            if synthesizer.isPaused {
                synthesizer.continueSpeaking()
            }
            speakNextIfIdle()
        }
    }

    /// NVDA's cancel, as sent by the PC.
    ///
    /// NVDA interrupts itself for every keystroke echo ("speech interrupt for
    /// typed characters"), so honouring each one literally means fast typing
    /// plays only the last letter: on the PC the synth starts instantly, but
    /// here the letter is still in the pipeline — more so over Bluetooth,
    /// whose output latency widens the window — and gets thrown away before
    /// it is audible. While the outstanding speech is nothing but keystroke
    /// echoes and we are keeping up, the letters queue instead. Fall far
    /// enough behind and the cancel is honoured again, so holding a key
    /// cannot leave the phone reading out a paragraph of stale letters.
    func remoteCancel() {
        if isTypingBurst {
            onTypingCancelHeld?()
            return
        }
        cancelAll()
    }

    private var isTypingBurst: Bool {
        guard lastEnqueuedBrief, !isIdle, pending.count <= maxTypingBacklog else { return false }
        return pending.allSatisfy { step in
            guard case .utterance(let utterance) = step else { return true }
            return utterance.speechString.count <= briefCharacterLimit
        }
    }

    func cancelAll() {
        lastEnqueuedBrief = false
        // NVDA clears its own pause when speech is cancelled, so a stale
        // pause must never outlive the queue it was holding.
        if isPaused {
            setPaused(false)
        }
        pending.removeAll()
        interruptCurrentUtterance()
        if isIdle {
            onActivity?(false)
        }
    }

    var isIdle: Bool {
        !speaking && trimmedPlayer.isIdle && pending.isEmpty
    }

    // MARK: - Queue pump

    private func interruptCurrentUtterance() {
        // Stopping the player drops every buffer already scheduled, so an
        // interrupt still clears everything at once even though scheduling
        // now runs ahead of playback.
        trimmedPlayer.stopAll()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            // didCancel fires and pumps the queue.
        }
    }

    private func speakNextIfIdle() {
        guard !isPaused else { return }
        if trimmingActive {
            pumpTrimmed()
            return
        }
        guard !speaking else { return }
        guard !pending.isEmpty else {
            onActivity?(false)
            return
        }
        speaking = true
        onActivity?(true)
        let step = pending.removeFirst()
        switch step {
        case .utterance(let utterance):
            lastEnqueuedBrief = utterance.speechString.count <= briefCharacterLimit
            synthesizer.speak(utterance)
        case .beep(let hz, let ms, let pan):
            // NVDA beeps (tones.beep) are asynchronous: play and move on.
            beepPlayer.play(hz: hz, ms: ms, pan: pan)
            speaking = false
            speakNextIfIdle()
        }
    }

    /// Keeps the player one utterance ahead of what it is playing, so
    /// consecutive utterances join without a seam — the gap NVDA's
    /// one-utterance-per-character spelling used to pay at every letter.
    private func pumpTrimmed() {
        // A fallback utterance on the system path owns the audio until done.
        guard !speaking, !isPaused else { return }
        while let step = pending.first {
            switch step {
            case .utterance(let utterance):
                guard trimmedPlayer.canAcceptMore else { return }
                pending.removeFirst()
                onActivity?(true)
                lastEnqueuedBrief = utterance.speechString.count <= briefCharacterLimit
                trimmedPlayer.enqueue(utterance)
            case .beep(let hz, let ms, let pan):
                // Beeps play on their own node the moment they are reached,
                // so they must not overtake audio still scheduled ahead.
                guard trimmedPlayer.isIdle else { return }
                pending.removeFirst()
                beepPlayer.play(hz: hz, ms: ms, pan: pan)
            }
        }
        if isIdle {
            onActivity?(false)
        }
    }

    /// Turning shortening off for good on a run of failures cost the user
    /// the feature until they restarted the app — a heavy price for what is
    /// usually a transient. Off for a minute, then it tries again.
    private func disableTrimmingTemporarily(_ reason: String) {
        trimDisabled = true
        trimFailureStreak = 0
        onTrimFailure?("\(reason) — pause shortening off for a minute")
        trimRearm?.cancel()
        let rearm = DispatchWorkItem { [weak self] in
            self?.trimDisabled = false
        }
        trimRearm = rearm
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: rearm)
    }

    /// A route change or session reconfiguration took the audio graph down
    /// with speech still scheduled on it. Put the lost utterances back at the
    /// front and carry on: nothing about this is the voice's fault, so it
    /// must not count towards disabling shortening.
    private func recoverFromAudioReset(_ lost: [AVSpeechUtterance]) {
        for utterance in lost.reversed() {
            pending.insert(.utterance(utterance), at: 0)
        }
        onAudioReset?()
        speakNextIfIdle()
    }

    /// A render failed. The utterances that never reached the audio node are
    /// put back at the front and spoken the ordinary way: pause shortening is
    /// a comfort feature, and losing a line of speech to it would be a bug
    /// worth more than the feature.
    private func handleTrimFailure(_ reason: String, returned: [AVSpeechUtterance]) {
        trimFailureStreak += 1
        if trimFailureStreak >= 3 {
            // Otherwise every utterance pays a failed render before speaking.
            disableTrimmingTemporarily(reason)
        } else {
            onTrimFailure?(reason)
        }
        for utterance in returned.reversed() {
            pending.insert(.utterance(utterance), at: 0)
        }
        speakNextIfIdle()
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.onUtteranceStarted?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speaking = false
            self.speakNextIfIdle()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.speaking = false
            self.speakNextIfIdle()
        }
    }

    // MARK: - Sequence → utterances

    private func buildSteps(from envelope: SpeechEnvelope) -> [Step] {
        var steps: [Step] = []
        var state = ProsodyState()
        var pendingDelayMs = 0
        var textRun: [String] = []

        func flushTextRun() {
            guard !textRun.isEmpty else { return }
            let text = textRun.joined(separator: " ")
            textRun.removeAll()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice(for: state.lang)
            utterance.rate = mappedRate(state.rate)
            utterance.pitchMultiplier = mappedPitch(state.pitch)
            utterance.volume = mappedVolume(state.volume)
            if pendingDelayMs > 0 {
                utterance.preUtteranceDelay = TimeInterval(pendingDelayMs) / 1000.0
                pendingDelayMs = 0
            }
            steps.append(.utterance(utterance))
        }

        for item in envelope.items {
            switch item {
            case .text(let value):
                if state.characterMode {
                    // NVDA has already split spelling into single-character
                    // strings; keeping each as its own utterance yields the
                    // spelled-out cadence.
                    flushTextRun()
                    textRun = [value]
                    flushTextRun()
                } else {
                    textRun.append(value)
                }
            case .phoneme(_, let fallback):
                // No AVSpeech equivalent for raw IPA; NVDA supplies fallback text.
                if let fallback, !fallback.isEmpty {
                    textRun.append(fallback)
                }
            case .pitch(let offset, let multiplier):
                flushTextRun()
                state.pitch = (offset, multiplier)
            case .rate(let offset, let multiplier):
                flushTextRun()
                state.rate = (offset, multiplier)
            case .volume(let offset, let multiplier):
                flushTextRun()
                state.volume = (offset, multiplier)
            case .lang(let lang):
                flushTextRun()
                state.lang = lang
            case .characterMode(let on):
                flushTextRun()
                state.characterMode = on
            case .pause(let ms):
                flushTextRun()
                pendingDelayMs += ms
            case .endUtterance:
                flushTextRun()
            case .beep(let hz, let ms, let left, let right):
                flushTextRun()
                steps.append(.beep(hz: hz, ms: ms, pan: Float((right - left) / 100.0)))
            case .index, .unknown:
                // Index markers: no audio effect (kept for a future transcript view).
                break
            }
        }
        flushTextRun()
        return steps
    }

    // MARK: - Prosody mapping

    /// NVDA settings live on a 0–100 scale with 50 as the nominal midpoint;
    /// an offset of +30 at base 50 is a 1.6× multiplier.
    private func effectiveMultiplier(_ value: (offset: Int, multiplier: Double?)) -> Float {
        if let multiplier = value.multiplier {
            return Float(multiplier)
        }
        return Float(50 + value.offset) / 50.0
    }

    private func mappedPitch(_ value: (offset: Int, multiplier: Double?)) -> Float {
        min(max(basePitch * effectiveMultiplier(value), 0.5), 2.0)
    }

    private func mappedRate(_ value: (offset: Int, multiplier: Double?)) -> Float {
        min(
            max(baseRate * effectiveMultiplier(value), AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
    }

    private func mappedVolume(_ value: (offset: Int, multiplier: Double?)) -> Float {
        min(max(baseVolume * effectiveMultiplier(value), 0.0), 1.0)
    }

    // MARK: - Voices

    /// A language change mid-sequence means a different voice for that
    /// segment (one AVSpeechUtterance is one voice).
    private func voice(for lang: String?) -> AVSpeechSynthesisVoice? {
        guard let lang, !lang.isEmpty else {
            if let id = baseVoiceIdentifier {
                return AVSpeechSynthesisVoice(identifier: id)
            }
            return nil
        }
        let bcp47 = lang.replacingOccurrences(of: "_", with: "-")
        if let cached = voiceCache[bcp47] {
            return cached ?? defaultVoice()
        }
        let voice = AVSpeechSynthesisVoice(language: bcp47)
            ?? AVSpeechSynthesisVoice(language: String(bcp47.prefix(2)))
        voiceCache[bcp47] = voice
        return voice ?? defaultVoice()
    }

    private func defaultVoice() -> AVSpeechSynthesisVoice? {
        if let id = baseVoiceIdentifier {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        return nil
    }
}
