import AVFoundation
import Foundation

/// Speaks utterances the long way round: render each to PCM, shorten the
/// silence, play the result on our own engine. That is the only route on
/// iOS to Eloquence-style pause shortening — Apple's voices expose no pause
/// control, and every attempt to fake one by editing the text failed.
///
/// It renders **one utterance ahead** and schedules each buffer on the player
/// node as soon as it is ready, so consecutive utterances play back to back
/// with no seam. That is what makes spelling sound like Windows: NVDA sends
/// one utterance per character, and the old play-wait-play pump paid a gap at
/// every letter.
///
/// Main-thread only; every callback is delivered on main. It runs its own
/// `AVAudioEngine` rather than sharing `BeepPlayer`'s, so the field-tested
/// keep-alive path stays untouched while this is young.
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
    }

    /// One utterance ahead of the one being played. A letter is 200–300 ms of
    /// audio and renders in tens of ms, so a deeper queue would buy nothing
    /// and would only widen what an interrupt has to throw away.
    private let lookAhead = 2

    var mode: PauseMode = .off
    var factor: Double = 0.3
    var trimmer = SilenceTrimmer()

    /// Each utterance handed to the audio node. Slightly ahead of the audible
    /// start now that scheduling runs ahead of playback.
    var onStarted: (() -> Void)?

    /// Every render's statistics, success or failure. For diagnostics.
    var onOutcome: ((Outcome) -> Void)?

    /// A render failed. Carries every utterance that did not make it to the
    /// audio node, in order, and fires only once the already-scheduled audio
    /// has drained — so the caller can speak them the ordinary way without
    /// talking over what is still playing.
    var onFailure: ((String, [AVSpeechUtterance]) -> Void)?

    /// Fired after every step forward — a render finishing, a buffer
    /// finishing playback. The caller uses it to top the queue up again, so
    /// feeding never stalls waiting for the whole batch to drain.
    var onProgress: (() -> Void)?

    private struct Job {
        var utterance: AVSpeechUtterance
        var mode: PauseMode
        var silent: Bool
    }

    private let renderer = SpeechBufferRenderer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?

    private var queued: [Job] = []
    private var rendering = false
    private var scheduled = 0
    private var failureReason: String?
    private var returned: [AVSpeechUtterance] = []

    /// Bumped on every stop; stale callbacks check it. Main thread only,
    /// which is what makes the checks race-free.
    private var generation = 0

    var isIdle: Bool {
        !rendering && queued.isEmpty && scheduled == 0
    }

    /// Room for another utterance without running further ahead than one.
    var canAcceptMore: Bool {
        scheduled + queued.count + (rendering ? 1 : 0) < lookAhead
    }

    /// - Parameters:
    ///   - modeOverride: for the probe's A/B, which plays the same render
    ///     both shortened and not.
    ///   - silent: render and measure without playing.
    func enqueue(_ utterance: AVSpeechUtterance, modeOverride: PauseMode? = nil, silent: Bool = false) {
        queued.append(Job(utterance: utterance, mode: modeOverride ?? mode, silent: silent))
        startNextRender()
    }

    /// Stops playback and everything queued, and reports whether there was
    /// anything to stop. Pending callbacks are dropped: the caller drives its
    /// own queue after an interrupt.
    @discardableResult
    func stopAll() -> Bool {
        guard !isIdle else { return false }
        generation += 1
        // `rendering` is deliberately left alone: the in-flight render's
        // completion resets it. Clearing it here would start a second render
        // while the first still holds the synthesizer.
        queued.removeAll()
        scheduled = 0
        failureReason = nil
        returned.removeAll()
        player.stop()
        return true
    }

    /// Shuts the engine down between bursts of speech. It is a second engine
    /// beside the keep-alive one, and two idling audio graphs is a battery
    /// cost with nothing to show for it.
    func releaseEngine() {
        guard isIdle, engine.isRunning else { return }
        engine.stop()
    }

    // MARK: - Render pipeline

    private func startNextRender() {
        guard !rendering, !queued.isEmpty else { return }
        rendering = true
        let job = queued.removeFirst()
        let token = generation
        let delay = job.utterance.preUtteranceDelay
        renderer.render(job.utterance.renderCopy()) { [weak self] result in
            guard let self else { return }
            self.rendering = false
            defer { self.startNextRender() }
            guard token == self.generation else { return }
            self.handle(result, job: job, delay: delay, token: token)
        }
    }

    private func handle(
        _ result: SpeechBufferRenderer.Result,
        job: Job,
        delay: TimeInterval,
        token: Int
    ) {
        var outcome = Outcome()
        outcome.renderSeconds = result.renderSeconds
        outcome.bufferCount = result.bufferCount

        guard let rendered = result.buffer, result.failure == nil else {
            outcome.failure = result.failure ?? "voice returned no audio"
            onOutcome?(outcome)
            fail(reason: outcome.failure ?? "render failed", from: job)
            return
        }

        let format = rendered.format
        outcome.sampleRate = format.sampleRate
        outcome.channels = format.channelCount
        outcome.analysis = trimmer.analyze(rendered)
        outcome.originalSeconds = outcome.analysis.totalSeconds

        let audio = trimmer.trimmed(rendered, mode: job.mode, factor: factor)
        outcome.playedSeconds = Double(audio.frameLength) / format.sampleRate

        guard !job.silent else {
            onOutcome?(outcome)
            progress()
            return
        }

        if let failure = prepareEngine(format: format) {
            outcome.failure = failure
            onOutcome?(outcome)
            fail(reason: failure, from: job)
            return
        }

        // Explicit breaks are the sender's, not the voice's; shorten them
        // only when the user asked for all pauses (the driver rate-scales
        // them the same way).
        let leading = job.mode == .all ? delay * factor : delay
        if leading > 0, let gap = SilenceTrimmer.silence(seconds: leading, format: format) {
            player.scheduleBuffer(gap, at: nil, options: [])
        }
        scheduled += 1
        player.scheduleBuffer(audio, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.scheduled -= 1
                self.progress()
            }
        }
        player.play()
        onStarted?()
        onOutcome?(outcome)
    }

    /// A failed render takes everything behind it with it: those utterances
    /// never reached the node, and speaking them out of order would be worse
    /// than the pause we were trying to shorten.
    private func fail(reason: String, from job: Job) {
        failureReason = reason
        returned.append(job.utterance)
        returned.append(contentsOf: queued.map(\.utterance))
        queued.removeAll()
        progress()
    }

    /// The failure is held back until the audio already scheduled has
    /// drained, so the caller's fall-back never talks over what is playing.
    private func progress() {
        if isIdle, let reason = failureReason {
            let utterances = returned
            failureReason = nil
            returned.removeAll()
            onFailure?(reason, utterances)
            return
        }
        onProgress?()
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
