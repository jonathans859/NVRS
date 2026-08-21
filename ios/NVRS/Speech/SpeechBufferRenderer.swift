import AVFoundation
import Foundation

/// Renders an utterance to PCM instead of playing it, via
/// `AVSpeechSynthesizer.write(_:toBufferCallback:)`.
///
/// Field-measured on Apple's 16 kHz voices: about 20× real time once warm,
/// so a one-second utterance costs ~50 ms before playback can start. The
/// first render after launch costs roughly three times that (engine warm-up).
final class SpeechBufferRenderer {
    struct Result {
        /// All buffers concatenated into one, in standard float format.
        /// Nil means the voice gave us nothing usable — the caller must fall
        /// back to ordinary `speak()` rather than drop the speech.
        var buffer: AVAudioPCMBuffer?
        var bufferCount = 0
        var emptyBuffers = 0
        var unreadableBuffers = 0
        var renderSeconds: Double = 0
        /// How long the renderer sat idle before this render was asked for.
        /// Nil for the first one. A render that hangs is suspected to be a
        /// cold re-warm, and it is the quiet before it — not its own
        /// duration — that would show that.
        var idleSeconds: Double?
        var timedOut = false
        /// The first attempt came back empty and we asked again.
        var retried = false

        var failure: String? {
            if timedOut { return "render timed out" }
            if buffer == nil { return "voice returned no audio" }
            return nil
        }
    }

    /// How long one render may take before the caller gives up on it and
    /// speaks the utterance the ordinary way, scaled by how much text there
    /// is.
    ///
    /// Measured over 1425 field renders: about 30 ms fixed plus 0.3 ms per
    /// character at the worst (92 ms for 309 characters). A flat 3 s was
    /// therefore 33x the slowest healthy render — and since the watchdog only
    /// ever fires on a stall, that number was really deciding how long a
    /// stall is allowed to sound like silence. Three seconds of it, three
    /// times over, is what one bad minute sounded like in the field.
    ///
    /// This is roughly 5x the measured cost at every length: 0.6 s for short
    /// text, 3.3 s at a 2000-character limit. Past 400 characters it is
    /// extrapolation — nothing longer reached the renderer before — so watch
    /// `lastTimeoutCharacters` in the diagnostics for honest renders being
    /// cut off.
    private let timeoutBase: TimeInterval = 0.3
    private let timeoutPerCharacter: TimeInterval = 0.0015
    /// The first render after launch costs about three times a warm one, and
    /// a cold re-warm after a long idle is suspected to do the same. For
    /// short utterances the floor is what covers that.
    private let timeoutFloor: TimeInterval = 0.6

    func timeout(forCharacters characters: Int) -> TimeInterval {
        max(timeoutFloor, timeoutBase + Double(characters) * timeoutPerCharacter)
    }

    /// Back-to-back `write()` calls on one synthesizer return nothing at all
    /// for the second one often enough to matter — measured while spelling,
    /// where utterances are one character and follow each other as fast as
    /// they render. A short breather between writes, and one retry when a
    /// render still comes back empty, is what keeps letters from vanishing.
    private let minimumWriteGap: TimeInterval = 0.03
    private let retryDelay: TimeInterval = 0.08

    /// The render after an aborted write goes to a synthesizer built seconds
    /// ago, so it is cold as well as new; this gives it a moment before the
    /// next write lands on it. Not measured — the retry above remains the
    /// real safety net, and the length-scaled allowance already carries
    /// enough headroom for a cold render (3x a warm one, against a floor of
    /// 5x) that a fresh instance should not time out on arrival.
    private let abortSettleGap: TimeInterval = 0.12

    private let queue = DispatchQueue(label: "com.jonathan859.nvrs.bufferrender")
    /// Replaced outright whenever a write hangs, so it is main-queue-only:
    /// every read and the one write below happen there.
    private var synthesizer = AVSpeechSynthesizer()

    private var busy = false
    private var buffers: [AVAudioPCMBuffer] = []
    private var result = Result()
    private var startedAt: CFAbsoluteTime = 0
    private var finishedAt: CFAbsoluteTime = 0
    private var attempt = 0
    /// The previous write was aborted rather than finished, so the next one
    /// waits longer before assuming the synthesizer is free.
    private var abortedWrite = false
    private var pendingUtterance: AVSpeechUtterance?
    /// Identifies which `write()` call a buffer belongs to. The callback
    /// itself carries no such marker, so buffers arriving late from a write
    /// we have already given up on would otherwise be collected as part of
    /// the *next* utterance — which is how spelling ended up saying letters
    /// that were never asked for.
    private var writeToken = 0
    private var watchdog: DispatchWorkItem?
    private var completion: ((Result) -> Void)?

    /// Completion is always delivered on the main queue, exactly once.
    func render(_ utterance: AVSpeechUtterance, completion: @escaping (Result) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.busy else {
                // Reported as a failure, which means the caller speaks it the
                // ordinary way rather than losing it.
                DispatchQueue.main.async { completion(Result()) }
                return
            }
            self.busy = true
            self.buffers = []
            self.result = Result()
            self.completion = completion
            self.attempt = 0
            self.pendingUtterance = utterance
            self.startedAt = CFAbsoluteTimeGetCurrent()
            if self.finishedAt > 0 {
                self.result.idleSeconds = self.startedAt - self.finishedAt
            }
            self.startWrite(after: 0)
        }
    }

    private func startWrite(after extraDelay: TimeInterval) {
        guard let utterance = pendingUtterance else { return }
        writeToken += 1
        let token = writeToken
        let sinceLastWrite = CFAbsoluteTimeGetCurrent() - finishedAt
        let gap = abortedWrite ? abortSettleGap : minimumWriteGap
        abortedWrite = false
        let delay = max(gap - sinceLastWrite, 0) + extraDelay

        let watchdog = DispatchWorkItem { [weak self] in
            self?.finish(timedOut: true)
        }
        self.watchdog = watchdog
        let allowance = timeout(forCharacters: utterance.speechString.count)
        queue.asyncAfter(deadline: .now() + delay + allowance, execute: watchdog)

        // Drive the synthesizer from the main thread, like the ordinary
        // speak() path — write-versus-speak should be the only difference.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.synthesizer.write(utterance) { [weak self] buffer in
                // The callback arrives on an internal queue and the buffer
                // may be recycled afterwards, so copy immediately.
                self?.queue.async {
                    self?.accept(buffer, from: token)
                }
            }
        }
    }

    // MARK: - Collection (private queue)

    private func accept(_ buffer: AVAudioBuffer, from token: Int) {
        // Anything from a superseded write belongs to an utterance we are no
        // longer rendering; collecting it would corrupt this one.
        guard busy, token == writeToken else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            result.unreadableBuffers += 1
            return
        }
        // A zero-length buffer is the documented end-of-stream signal.
        guard pcm.frameLength > 0 else {
            result.emptyBuffers += 1
            finish(timedOut: false)
            return
        }
        if let converted = Self.floatCopy(of: pcm) {
            buffers.append(converted)
            result.bufferCount += 1
        } else {
            result.unreadableBuffers += 1
        }
    }

    private func finish(timedOut: Bool) {
        guard busy else { return }
        watchdog?.cancel()
        watchdog = nil
        finishedAt = CFAbsoluteTimeGetCurrent()

        if timedOut {
            // The write that never came back still holds the synthesizer, and
            // a fresh write() issued against a busy one returns nothing at all
            // — which is how a single timeout became a run of failed renders
            // and a stretch of unshortened pauses.
            //
            // stopSpeaking() was the first attempt at letting go of it, and
            // the field says it does not work: build 36 logged a session where
            // the successful-render count froze the moment the first write
            // hung and never moved again, while every later render timed out,
            // including one-character ones. write() has no cancel, and a
            // wedged instance stays wedged for the life of the process —
            // which is why the only cure anyone found was restarting the app.
            //
            // So throw the instance away instead. Late buffers from the dead
            // one are already ignored by `writeToken`, and it is released once
            // its write returns, if it ever does — a synthesizer leaked per
            // hang is a far smaller price than losing shortening until relaunch.
            abortedWrite = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                self.synthesizer = AVSpeechSynthesizer()
            }
        }

        // An empty result is usually the synthesizer not being ready yet
        // rather than a voice that cannot render; ask once more before
        // giving up, because giving up costs a spoken letter.
        if buffers.isEmpty, !timedOut, attempt == 0 {
            attempt = 1
            result.retried = true
            startWrite(after: retryDelay)
            return
        }

        busy = false
        pendingUtterance = nil
        result.renderSeconds = CFAbsoluteTimeGetCurrent() - startedAt
        result.timedOut = timedOut
        // A timeout means we may be holding half an utterance; speaking half
        // of something is worse than falling back, so hand back nothing.
        result.buffer = timedOut ? nil : SilenceTrimmer.concatenated(buffers)
        buffers = []
        let finished = result
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async {
            completion?(finished)
        }
    }

    // MARK: - Format normalisation

    /// Copies any PCM buffer into a standard non-interleaved float buffer.
    /// Apple's TTS hands back int16 for several voices, and
    /// `AVAudioPlayerNode` insists on the format its connection was made
    /// with, so normalising once here removes both problems.
    static func floatCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(source.channelCount)
        guard frames > 0, channels > 0,
              let target = AVAudioFormat(
                  standardFormatWithSampleRate: source.sampleRate,
                  channels: source.channelCount
              ),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)),
              let destination = output.floatChannelData
        else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        let step = source.isInterleaved ? channels : 1

        switch source.commonFormat {
        case .pcmFormatFloat32:
            guard let samples = buffer.floatChannelData else { return nil }
            for channel in 0..<channels {
                let base = source.isInterleaved ? samples[0] + channel : samples[channel]
                for frame in 0..<frames {
                    destination[channel][frame] = base[frame * step]
                }
            }
        case .pcmFormatInt16:
            guard let samples = buffer.int16ChannelData else { return nil }
            let scale = Float(1.0 / 32768.0)
            for channel in 0..<channels {
                let base = source.isInterleaved ? samples[0] + channel : samples[channel]
                for frame in 0..<frames {
                    destination[channel][frame] = Float(base[frame * step]) * scale
                }
            }
        case .pcmFormatInt32:
            guard let samples = buffer.int32ChannelData else { return nil }
            let scale = Float(1.0 / 2147483648.0)
            for channel in 0..<channels {
                let base = source.isInterleaved ? samples[0] + channel : samples[channel]
                for frame in 0..<frames {
                    destination[channel][frame] = Float(base[frame * step]) * scale
                }
            }
        default:
            return nil
        }
        return output
    }
}
