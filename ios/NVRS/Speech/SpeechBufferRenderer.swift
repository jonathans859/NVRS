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
        var timedOut = false
        /// The first attempt came back empty and we asked again.
        var retried = false

        var failure: String? {
            if timedOut { return "render timed out" }
            if buffer == nil { return "voice returned no audio" }
            return nil
        }
    }

    /// A voice that hasn't finished by now is not going to be usable for a
    /// live mirror; the caller falls back to `speak()` instead of waiting.
    var timeout: TimeInterval = 3.0

    /// Back-to-back `write()` calls on one synthesizer return nothing at all
    /// for the second one often enough to matter — measured while spelling,
    /// where utterances are one character and follow each other as fast as
    /// they render. A short breather between writes, and one retry when a
    /// render still comes back empty, is what keeps letters from vanishing.
    private let minimumWriteGap: TimeInterval = 0.03
    private let retryDelay: TimeInterval = 0.08

    private let queue = DispatchQueue(label: "com.jonathan859.nvrs.bufferrender")
    private let synthesizer = AVSpeechSynthesizer()

    private var busy = false
    private var buffers: [AVAudioPCMBuffer] = []
    private var result = Result()
    private var startedAt: CFAbsoluteTime = 0
    private var finishedAt: CFAbsoluteTime = 0
    private var attempt = 0
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
            self.startWrite(after: 0)
        }
    }

    private func startWrite(after extraDelay: TimeInterval) {
        guard let utterance = pendingUtterance else { return }
        writeToken += 1
        let token = writeToken
        let sinceLastWrite = CFAbsoluteTimeGetCurrent() - finishedAt
        let delay = max(minimumWriteGap - sinceLastWrite, 0) + extraDelay

        let watchdog = DispatchWorkItem { [weak self] in
            self?.finish(timedOut: true)
        }
        self.watchdog = watchdog
        queue.asyncAfter(deadline: .now() + delay + timeout, execute: watchdog)

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
