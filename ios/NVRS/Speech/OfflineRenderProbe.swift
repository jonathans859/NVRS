import AVFoundation
import Foundation

/// Diagnostics for pause shortening (see
/// `.claude-notes/pause-shortening-ios-v4.md`).
///
/// It drives `TrimmedUtterancePlayer` — the same component the mirroring
/// path uses when shortening is on — so a good probe result and a good live
/// result mean the same thing. It only adds the report.
///
/// Main-thread only, like the player it drives; the report comes back on main.
final class OfflineRenderProbe {
    /// Packed with every punctuation class that triggers a pause, so one run
    /// yields the calibration data for the shortening factor.
    static let phrase = "One, two, three. Four? Five! Six: seven; eight."

    /// Spelled one character per utterance, exactly as NVDA sends spelling.
    static let word = "Eloquence"

    struct Report {
        var headline: String
        var lines: [String]
    }

    private let player: TrimmedUtterancePlayer

    init(host: AudioEngineHost) {
        player = TrimmedUtterancePlayer(host: host)
    }

    /// - Parameters:
    ///   - mode: usually the user's setting; `.off` gives the unshortened
    ///     reference for an A/B comparison by ear.
    ///   - silent: measure without playing.
    func run(
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float,
        mode: PauseMode,
        factor: Double,
        silent: Bool,
        completion: @escaping (Report) -> Void
    ) {
        let utterance = AVSpeechUtterance(string: Self.phrase)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        // Leftover state from an earlier run must never make the next one
        // look busy — that is what left the buttons dimmed for good.
        player.stopAll()
        player.factor = factor
        player.onProgress = nil
        // The failure already reaches the report through onOutcome.
        player.onFailure = nil
        player.onOutcome = { outcome in
            completion(Self.report(for: outcome, voice: voice, mode: mode, factor: factor, silent: silent))
        }
        player.enqueue(utterance, modeOverride: mode, silent: silent)
    }

    /// Spells a word one utterance per character — the case where the phone
    /// used to fall far behind Windows — and measures the wall clock against
    /// the audio actually produced. The difference is the gaps.
    ///
    /// Feeds with the same look-ahead discipline as `SpeechRenderer`, so the
    /// number means what the live path does, not what a best case could do.
    func spell(
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float,
        mode: PauseMode,
        factor: Double,
        completion: @escaping (Report) -> Void
    ) {
        var remaining = Self.word.map { character -> AVSpeechUtterance in
            let utterance = AVSpeechUtterance(string: String(character))
            utterance.voice = voice
            utterance.rate = rate
            utterance.pitchMultiplier = pitch
            utterance.volume = volume
            return utterance
        }
        let letters = remaining.count
        var audioSeconds = 0.0
        var renderSeconds = 0.0
        var failure: String?
        let startedAt = CFAbsoluteTimeGetCurrent()
        var finished = false

        player.stopAll()
        player.factor = factor
        player.onOutcome = { outcome in
            audioSeconds += outcome.playedSeconds
            renderSeconds += outcome.renderSeconds
            if let reason = outcome.failure, failure == nil {
                failure = reason
            }
        }
        // Captures only locals on purpose: referencing the player here would
        // close the loop player → callback → probe → player.
        func finish() {
            guard !finished else { return }
            finished = true
            completion(
                Self.spellReport(
                    voice: voice,
                    letters: letters,
                    audioSeconds: audioSeconds,
                    renderSeconds: renderSeconds,
                    wallClock: CFAbsoluteTimeGetCurrent() - startedAt,
                    mode: mode,
                    factor: factor,
                    failure: failure
                )
            )
        }

        player.onProgress = { [weak self] in
            guard let self, !finished else { return }
            while !remaining.isEmpty, self.player.canAcceptMore {
                self.player.enqueue(remaining.removeFirst(), modeOverride: mode)
            }
            guard remaining.isEmpty, self.player.isIdle else { return }
            finish()
        }
        // A failed render stops the run rather than hanging the report.
        player.onFailure = { reason, _ in
            if failure == nil { failure = reason }
            remaining.removeAll()
            finish()
        }
        while !remaining.isEmpty, player.canAcceptMore {
            player.enqueue(remaining.removeFirst(), modeOverride: mode)
        }
    }

    // MARK: - Report

    private static func report(
        for outcome: TrimmedUtterancePlayer.Outcome,
        voice: AVSpeechSynthesisVoice?,
        mode: PauseMode,
        factor: Double,
        silent: Bool
    ) -> Report {
        var lines = [
            "Voice: \(voice?.name ?? "system default") (\(voice?.language ?? "-")).",
            // The identifier is what settles whether this is Apple's
            // Eloquence port; the persona names overlap with other voices.
            "Identifier: \(voice?.identifier ?? "none").",
        ]

        if let failure = outcome.failure {
            lines.append("Render failed: \(failure).")
            lines.append("Buffers: \(outcome.bufferCount).")
            lines.append("Offline rendering is unavailable here, so pause shortening cannot work with this voice.")
            return Report(headline: "Render failed: \(failure)", lines: lines)
        }

        let analysis = outcome.analysis
        lines.append("Buffers: \(outcome.bufferCount), \(Int(outcome.sampleRate)) hertz, \(outcome.channels) channel.")
        lines.append("Audio length: \(ms(outcome.originalSeconds)).")
        lines.append("Render time: \(ms(outcome.renderSeconds)) — \(ratio(outcome.originalSeconds, outcome.renderSeconds)) times real time.")
        lines.append("Noise floor: \(dB(analysis.noiseFloorDB)). Silence threshold: minus 50 dBFS.")
        if analysis.noiseFloorDB > -55, analysis.noiseFloorDB.isFinite {
            lines.append("Warning: the noise floor is close to the threshold, so pause lengths may be split and under-reported.")
        }
        lines.append("Pauses over 40 milliseconds: \(analysis.pauses.count), totalling \(ms(analysis.pauses.reduce(0) { $0 + $1.seconds })).")
        if !analysis.pauses.isEmpty {
            let listed = analysis.pauses.prefix(12).map { String(Int($0.seconds * 1000)) }.joined(separator: ", ")
            lines.append("Pause lengths in milliseconds: \(listed).")
        }
        lines.append("Leading silence: \(ms(analysis.leadingSeconds)). Trailing silence: \(ms(analysis.trailingSeconds)). Interior: \(ms(analysis.interiorSeconds)).")

        lines.append("Mode: \(mode.label), keeping \(Int(factor * 100)) percent.")
        let saved = outcome.originalSeconds - outcome.playedSeconds
        lines.append("Result: \(ms(outcome.playedSeconds)) instead of \(ms(outcome.originalSeconds)) — \(ms(saved)) shorter, \(percent(saved, of: outcome.originalSeconds)) off.")
        lines.append(silent ? "Not played." : "Played through the app's own engine.")

        return Report(
            headline: "\(ms(outcome.playedSeconds)) of \(ms(outcome.originalSeconds)), \(analysis.pauses.count) pauses",
            lines: lines
        )
    }

    private static func spellReport(
        voice: AVSpeechSynthesisVoice?,
        letters: Int,
        audioSeconds: Double,
        renderSeconds: Double,
        wallClock: Double,
        mode: PauseMode,
        factor: Double,
        failure: String?
    ) -> Report {
        var lines = [
            "Spelled \(word), \(letters) letters, one utterance each.",
            "Voice: \(voice?.name ?? "system default").",
            "Mode: \(mode.label), keeping \(Int(factor * 100)) percent.",
        ]
        if let failure {
            lines.append("At least one render failed: \(failure).")
        }
        let gaps = max(wallClock - audioSeconds, 0)
        lines.append("Audio produced: \(ms(audioSeconds)).")
        lines.append("Wall clock: \(ms(wallClock)), including the first render.")
        lines.append("Gaps: \(ms(gaps)) in total, \(ms(gaps / Double(max(letters - 1, 1)))) per letter boundary.")
        lines.append("Rendering cost \(ms(renderSeconds)) altogether, hidden behind playback except for the first letter.")
        return Report(
            headline: "\(ms(gaps)) of gaps over \(letters) letters",
            lines: lines
        )
    }

    // MARK: - Formatting (this gets read aloud, so: words, not symbols)

    private static func ms(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) milliseconds"
    }

    private static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0 percent" }
        return "\(Int((part / whole * 100).rounded())) percent"
    }

    private static func ratio(_ audio: Double, _ render: Double) -> String {
        guard render > 0 else { return "an unknown number of" }
        return String(format: "%.1f", audio / render)
    }

    private static func dB(_ value: Double) -> String {
        guard value.isFinite else { return "true silence" }
        return "minus \(Int(-value.rounded())) dBFS"
    }
}
