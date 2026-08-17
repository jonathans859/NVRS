import AVFoundation
import Foundation

/// Speaks one utterance the long way round: render it to PCM, shorten the
/// silence, play the result on our own engine. That is the only route on
/// iOS to Eloquence-style pause shortening — Apple's voices expose no pause
/// control, and every attempt to fake one by editing the text failed.
///
/// Main-thread only, except where noted; every callback is delivered on main.
/// It runs its own `AVAudioEngine` rather than sharing `BeepPlayer`'s, so
/// the field-tested keep-alive path stays untouched while this is young.
final class TrimmedUtterancePlayer {
    struct Outcome {
        var failure: String?
        var renderSeconds: Double = 0
        var originalSeconds: Double = 0
        var playedSeconds: Double = 0
        var bufferCount = 0
        var sampleRate: Double = 0
        var channels: AVAudioChannelCount = 0
        var analysis = SilenceTrimmer.Analysis()

        var succeeded: Bool { failure == nil }
    }

    var mode: PauseMode = .off
    var factor: Double = 0.3
    var trimmer = SilenceTrimmer()

    /// Fires when audio actually starts, so the diagnostics counter keeps
    /// meaning the same thing on both paths.
    var onStarted: (() -> Void)?

    private let renderer = SpeechBufferRenderer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?

    /// Bumped on every new request and on stop; stale callbacks check it.
    /// Main thread only, which is what makes the checks race-free.
    private var generation = 0
    private(set) var isBusy = false

    /// - Parameters:
    ///   - modeOverride: for the probe's A/B, which needs to play the same
    ///     render both shortened and not.
    ///   - silent: render and measure without playing.
    ///   - completion: called when playback ends, or immediately on failure.
    ///     A failure means the caller must speak the utterance the ordinary
    ///     way — speech is never dropped because a render failed.
    func speak(
        _ utterance: AVSpeechUtterance,
        modeOverride: PauseMode? = nil,
        silent: Bool = false,
        completion: @escaping (Outcome) -> Void
    ) {
        generation += 1
        let token = generation
        isBusy = true
        let mode = modeOverride ?? self.mode
        let delay = utterance.preUtteranceDelay
        renderer.render(utterance.renderCopy()) { [weak self] result in
            guard let self, token == self.generation else { return }
            self.play(
                result,
                mode: mode,
                delay: delay,
                silent: silent,
                token: token,
                completion: completion
            )
        }
    }

    /// Shuts the engine down between bursts of speech. It is a second engine
    /// beside the keep-alive one, and two idling audio graphs is a battery
    /// cost with nothing to show for it.
    func releaseEngine() {
        guard !isBusy, engine.isRunning else { return }
        engine.stop()
    }

    /// Stops playback (or an in-flight render) and reports whether there was
    /// anything to stop. The pending completion is dropped: the caller drives
    /// its own queue after an interrupt.
    @discardableResult
    func stopIfPlaying() -> Bool {
        guard isBusy else { return false }
        generation += 1
        isBusy = false
        player.stop()
        return true
    }

    // MARK: - Playback

    private func play(
        _ result: SpeechBufferRenderer.Result,
        mode: PauseMode,
        delay: TimeInterval,
        silent: Bool,
        token: Int,
        completion: @escaping (Outcome) -> Void
    ) {
        var outcome = Outcome()
        outcome.renderSeconds = result.renderSeconds
        outcome.bufferCount = result.bufferCount

        guard let rendered = result.buffer, result.failure == nil else {
            outcome.failure = result.failure ?? "voice returned no audio"
            isBusy = false
            completion(outcome)
            return
        }

        let format = rendered.format
        outcome.sampleRate = format.sampleRate
        outcome.channels = format.channelCount
        outcome.analysis = trimmer.analyze(rendered)
        outcome.originalSeconds = outcome.analysis.totalSeconds

        let audio = trimmer.trimmed(rendered, mode: mode, factor: factor)
        outcome.playedSeconds = Double(audio.frameLength) / format.sampleRate

        guard !silent else {
            isBusy = false
            completion(outcome)
            return
        }

        if let failure = prepareEngine(format: format) {
            outcome.failure = failure
            isBusy = false
            completion(outcome)
            return
        }

        // Explicit breaks are the sender's, not the voice's; shorten them
        // only when the user asked for all pauses (the driver rate-scales
        // them the same way).
        let leading = mode == .all ? delay * factor : delay
        if leading > 0, let gap = SilenceTrimmer.silence(seconds: leading, format: format) {
            player.scheduleBuffer(gap, at: nil, options: [])
        }
        player.scheduleBuffer(audio, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.isBusy = false
                completion(outcome)
            }
        }
        player.play()
        onStarted?()
    }

    /// Returns a failure description, or nil when the engine is ready.
    private func prepareEngine(format: AVAudioFormat) -> String? {
        if !attached {
            engine.attach(player)
            attached = true
        }
        if connectedFormat?.sampleRate != format.sampleRate
            || connectedFormat?.channelCount != format.channelCount {
            if engine.isRunning {
                engine.stop()
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return "engine start failed: \(error.localizedDescription)"
            }
        }
        return nil
    }
}

extension AVSpeechUtterance {
    /// A copy for rendering: same voice and prosody, no delays — those are
    /// scheduled as real silence instead. Leaves the original untouched so
    /// it can still be handed to `speak()` if the render fails.
    func renderCopy() -> AVSpeechUtterance {
        let copy = AVSpeechUtterance(string: speechString)
        copy.voice = voice
        copy.rate = rate
        copy.pitchMultiplier = pitchMultiplier
        copy.volume = volume
        copy.preUtteranceDelay = 0
        copy.postUtteranceDelay = 0
        return copy
    }
}
