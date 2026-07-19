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
    private let beepPlayer = BeepPlayer()
    private var pending: [Step] = []
    private var speaking = false
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    /// Baselines, updated from Settings. Read on the main thread.
    var baseVoiceIdentifier: String?
    var baseRate: Float = AVSpeechUtteranceDefaultSpeechRate
    var basePitch: Float = 1.0
    var baseVolume: Float = 1.0

    /// Approximates the IBMTTS driver's "Shorten all pauses". Apple's
    /// Eloquence port does NOT parse ECI inline commands (`p1 is read
    /// aloud — field-tested), and stripping all punctuation broke meaning
    /// (German ordinals, question intonation — field-tested too). Current
    /// approach: strip only commas/semicolons in pause position, and cut
    /// sentence pauses by splitting utterances at sentence boundaries —
    /// every sentence keeps its punctuation, but the pause after it
    /// becomes our (fast) queue hop instead of the engine's long one.
    var shortenPauses = false

    /// Commas/semicolons after a word, before whitespace/end: pure pause
    /// prosody. Decimals ("1,5") never match — a digit follows the comma.
    private static let commaPauseRegex = try? NSRegularExpression(
        pattern: "([a-zA-Z0-9]|\\s)([,;])(\\2*?)(\\s|[\\\\/]|$)"
    )

    /// Whitespace right after sentence-final punctuation = split point.
    private static let sentenceSplitRegex = try? NSRegularExpression(
        pattern: "(?<=[.!?:])\\s+"
    )

    /// Called whenever the renderer starts or stops having work; drives
    /// audio session activation/idle handling.
    var onActivity: ((Bool) -> Void)?

    /// Called (on main) each time the synthesizer actually starts an
    /// utterance; drives the diagnostics counter.
    var onUtteranceStarted: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
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
        beepPlayer.stopKeepAlive()
    }

    func cancelAll() {
        pending.removeAll()
        interruptCurrentUtterance()
        if !speaking {
            onActivity?(false)
        }
    }

    var isIdle: Bool {
        !speaking && pending.isEmpty
    }

    // MARK: - Queue pump

    private func interruptCurrentUtterance() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            // didCancel fires and pumps the queue.
        }
    }

    private func speakNextIfIdle() {
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
            synthesizer.speak(utterance)
        case .beep(let hz, let ms, let pan):
            // NVDA beeps (tones.beep) are asynchronous: play and move on.
            beepPlayer.play(hz: hz, ms: ms, pan: pan)
            speaking = false
            speakNextIfIdle()
        }
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
            for fragment in speakableFragments(of: text) {
                let utterance = AVSpeechUtterance(string: fragment)
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
                // The PC driver scales explicit breaks down with speech
                // rate; approximate that when pause shortening is on.
                pendingDelayMs += shortenPauses ? min(ms / 5, 100) : ms
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

    // MARK: - Pause shortening

    /// With shortening off: the text as one fragment. With it on: commas
    /// de-paused, then split at sentence boundaries (punctuation kept)
    /// so the engine's sentence pause is replaced by the queue hop.
    private func speakableFragments(of text: String) -> [String] {
        guard shortenPauses else { return [text] }
        var result = text
        if let commaRegex = Self.commaPauseRegex {
            result = commaRegex.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1$4"
            )
        }
        guard let splitRegex = Self.sentenceSplitRegex else { return [result] }
        let marked = splitRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: NSRange(result.startIndex..., in: result),
            withTemplate: "\n"
        )
        return marked
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
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
