import AVFoundation
import Foundation

/// Speaks utterances the long way round: render each to PCM, shorten the
/// silence, play the result on the app's shared engine. That is the only route on
/// iOS to Eloquence-style pause shortening — Apple's voices expose no pause
/// control, and every attempt to fake one by editing the text failed.
///
/// It renders **one utterance ahead** and schedules each buffer on the player
/// node as soon as it is ready, so consecutive utterances play back to back
/// with no seam. That is what makes spelling sound like Windows: NVDA sends
/// one utterance per character, and the old play-wait-play pump paid a gap at
/// every letter.
///
/// Main-thread only; every callback is delivered on main. It shares one
/// `AudioEngineHost` with the beep player: two engines on one session
/// crackled and dropped audio, and stopping an engine between bursts cost the
/// start of the next one.
final class TrimmedUtterancePlayer {
    struct Outcome {
        var failure: String?
        var renderSeconds: Double = 0
        var originalSeconds: Double = 0
        var playedSeconds: Double = 0
        var bufferCount = 0
        var sampleRate: Double = 0
        var channels: AVAudioChannelCount = 0
        var retried = false
        /// Split out from `failure` so diagnostics can tell a hung render
        /// from a voice that simply gave us nothing: only one of the two is
        /// heard as a stall, and they have different causes.
        var timedOut = false
        var idleSeconds: Double?
        /// How long the utterance was. Paired with `renderSeconds` it gives
        /// cost against real text, which is what a length-scaled timeout has
        /// to be sized from - a flat one guillotines a long render that was
        /// working perfectly well.
        var characterCount = 0
        var analysis = SilenceTrimmer.Analysis()
    }

    /// How far ahead of playback we are willing to run. Depth one was too
    /// tight: with spelling, one letter is only ~250 ms of audio, so a render
    /// that ran a little long left the node with nothing queued — audible as
    /// crackle and as gaps of uneven length. Two limits, whichever binds
    /// first: a count (for many short utterances) and a duration (so a
    /// say-all of long ones doesn't render half a minute ahead).
    private let maxInFlight = 8
    private let maxScheduledSeconds = 2.0

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

    /// The audio graph was torn down under us (a route change, the session
    /// reconfiguring) and everything scheduled died with it. Carries the
    /// utterances that were lost, in order, so the caller can say them again.
    /// Not a failure of the voice, so it must not count towards disabling
    /// shortening — losing letters out of a spelled word is what this
    /// prevents.
    var onAudioReset: (([AVSpeechUtterance]) -> Void)?

    private struct Job {
        var utterance: AVSpeechUtterance
        var mode: PauseMode
        var silent: Bool
    }

    private let renderer = SpeechBufferRenderer()
    private let host: AudioEngineHost
    private let player = AVAudioPlayerNode()

    private var queued: [Job] = []
    /// Handed to the audio node and not yet finished playing, oldest first.
    private var inFlight: [AVSpeechUtterance] = []
    private var rendering = false
    /// The one being rendered right now: in neither queue, so it has to be
    /// tracked separately or a reset would drop exactly one utterance.
    private var renderingJob: Job?
    private var scheduled = 0
    private var scheduledSeconds = 0.0
    private var failureReason: String?
    private var returned: [AVSpeechUtterance] = []

    /// Bumped on every stop; stale callbacks check it. Main thread only,
    /// which is what makes the checks race-free.
    private var generation = 0

    init(host: AudioEngineHost) {
        self.host = host
        host.onAudioReset { [weak self] in
            self?.recoverFromAudioReset()
        }
    }

    /// Everything scheduled is gone. Reset the counters — the completion
    /// handlers for those buffers will never arrive — and hand the lost
    /// utterances back. The one that was mid-playback goes back too: a
    /// repeated letter is a blemish, a missing letter is a bug.
    private func recoverFromAudioReset() {
        let lost = inFlight
            + [renderingJob?.utterance].compactMap { $0 }
            + queued.map(\.utterance)
        guard !lost.isEmpty else { return }
        generation += 1
        player.stop()
        inFlight.removeAll()
        renderingJob = nil
        queued.removeAll()
        scheduled = 0
        scheduledSeconds = 0
        failureReason = nil
        returned.removeAll()
        onAudioReset?(lost)
    }

    var isIdle: Bool {
        !rendering && queued.isEmpty && scheduled == 0
    }

    var canAcceptMore: Bool {
        // Nothing new while a failure is waiting to be handed back: the
        // caller re-queues those utterances at the front, and letting later
        // ones in first would speak them out of order.
        failureReason == nil
            && scheduled + queued.count + (rendering ? 1 : 0) < maxInFlight
            && scheduledSeconds < maxScheduledSeconds
    }

    /// - Parameters:
    ///   - modeOverride: for the probe's A/B, which plays the same render
    ///     both shortened and not.
    ///   - silent: render and measure without playing.
    func enqueue(_ utterance: AVSpeechUtterance, modeOverride: PauseMode? = nil, silent: Bool = false) {
        queued.append(Job(utterance: utterance, mode: modeOverride ?? mode, silent: silent))
        startNextRender()
    }

    /// Holds playback where it is. Scheduled buffers stay scheduled and
    /// resume from the same point, which is what makes this a pause rather
    /// than a cancel.
    func setPaused(_ paused: Bool) {
        if paused {
            player.pause()
        } else if !isIdle {
            player.play()
        }
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
        inFlight.removeAll()
        renderingJob = nil
        scheduled = 0
        scheduledSeconds = 0
        failureReason = nil
        returned.removeAll()
        player.stop()
        return true
    }

    // MARK: - Render pipeline

    private func startNextRender() {
        guard !rendering, !queued.isEmpty else { return }
        rendering = true
        let job = queued.removeFirst()
        renderingJob = job
        let token = generation
        let delay = job.utterance.preUtteranceDelay
        renderer.render(job.utterance.renderCopy()) { [weak self] result in
            guard let self else { return }
            self.rendering = false
            self.renderingJob = nil
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
        outcome.retried = result.retried
        outcome.timedOut = result.timedOut
        outcome.idleSeconds = result.idleSeconds
        outcome.characterCount = job.utterance.speechString.count

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
        scheduledSeconds += outcome.playedSeconds
        inFlight.append(job.utterance)
        let playedSeconds = outcome.playedSeconds
        player.scheduleBuffer(audio, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, token == self.generation else { return }
                self.scheduled -= 1
                self.scheduledSeconds = max(self.scheduledSeconds - playedSeconds, 0)
                if !self.inFlight.isEmpty {
                    self.inFlight.removeFirst()
                }
                self.progress()
            }
        }
        player.play()
        watchStall(for: job.utterance, token: token)
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

    /// A buffer whose completion never arrives would sit in the queue for
    /// ever and take the rest of the word with it — which is how letters go
    /// missing from spelling. If it has not played by the time everything
    /// queued ahead of it could have played twice over, treat it as lost and
    /// say it again.
    private func watchStall(for utterance: AVSpeechUtterance, token: Int) {
        let deadline = scheduledSeconds + 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self] in
            guard let self, token == self.generation else { return }
            guard self.inFlight.contains(where: { $0 === utterance }) else { return }
            self.recoverFromAudioReset()
        }
    }

    /// Returns a failure description, or nil when the engine is ready.
    private func prepareEngine(format: AVAudioFormat) -> String? {
        host.connect(player, format: format)
        return host.start()
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
