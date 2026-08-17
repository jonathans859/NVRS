import AVFoundation
import Foundation

/// Spike for pause shortening (see `.claude-notes/pause-shortening-ios-v4.md`).
///
/// Renders a phrase with `AVSpeechSynthesizer.write(_:toBufferCallback:)`
/// instead of `speak()` and reports what came back: whether the selected
/// voice renders offline at all, how fast, and how much of its output is
/// silence. Optionally plays the buffers back *unmodified* through our own
/// `AVAudioEngine` — the risky half, kept isolated so a failure here can't
/// touch mirrored speech. Nothing in this file is on the production path.
final class OfflineRenderProbe {
    struct Report {
        var headline: String
        var lines: [String]
    }

    /// Packed with every punctuation class that triggers a pause, so one run
    /// yields the calibration data for the trimming factor.
    static let phrase = "One, two, three. Four? Five! Six: seven; eight."

    /// Anything quieter than this counts as silence. dB-based on purpose:
    /// ECI output has true digital silence, neural voices have a noise floor.
    private let silenceThreshold: Float = 0.00316 // −50 dBFS
    private let windowSeconds = 0.010
    /// Shorter gaps are coarticulation, not a pause worth touching.
    private let minPauseSeconds = 0.060
    private let watchdogSeconds = 15.0

    private let queue = DispatchQueue(label: "com.jonathan859.nvrs.renderprobe")
    private let synthesizer = AVSpeechSynthesizer()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var attached = false
    private var connectedFormat: AVAudioFormat?

    // Probe-queue state; valid only between run() and completion.
    private var running = false
    private var buffers: [AVAudioPCMBuffer] = []
    private var emptyBuffers = 0
    private var rejectedBuffers = 0
    private var startedAt: CFAbsoluteTime = 0
    private var watchdog: DispatchWorkItem?
    private var completion: ((Report) -> Void)?
    private var voiceLabel = ""
    private var shouldPlay = false

    /// - Parameter play: schedule the rendered buffers on our own engine
    ///   afterwards. False renders silently — the cheapest possible answer to
    ///   "does this voice support offline rendering at all".
    func run(
        phrase: String,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        pitch: Float,
        volume: Float,
        play: Bool,
        completion: @escaping (Report) -> Void
    ) {
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume
        let label = voice.map { "\($0.name) (\($0.language))" } ?? "system default"

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.running else {
                completion(Report(headline: "Probe already running", lines: ["A render is already in flight."]))
                return
            }
            self.running = true
            self.buffers = []
            self.emptyBuffers = 0
            self.rejectedBuffers = 0
            self.completion = completion
            self.voiceLabel = label
            self.shouldPlay = play
            self.startedAt = CFAbsoluteTimeGetCurrent()

            // Some voices never signal completion; never hang the UI on them.
            let watchdog = DispatchWorkItem { [weak self] in
                self?.finish(timedOut: true)
            }
            self.watchdog = watchdog
            self.queue.asyncAfter(deadline: .now() + self.watchdogSeconds, execute: watchdog)

            // Drive the synthesizer from the main thread, exactly like the
            // production `speak()` path — the only difference under test
            // should be write-versus-speak.
            DispatchQueue.main.async {
                self.synthesizer.write(utterance) { [weak self] buffer in
                    // The callback arrives on an internal queue and the buffer
                    // may be recycled after it returns — copy it right away.
                    self?.queue.async {
                        self?.accept(buffer)
                    }
                }
            }
        }
    }

    // MARK: - Collection (probe queue)

    private func accept(_ buffer: AVAudioBuffer) {
        guard running else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer else {
            rejectedBuffers += 1
            return
        }
        // A zero-length buffer is the documented end-of-stream signal.
        guard pcm.frameLength > 0 else {
            emptyBuffers += 1
            finish(timedOut: false)
            return
        }
        if let converted = Self.floatCopy(of: pcm) {
            buffers.append(converted)
        } else {
            rejectedBuffers += 1
        }
    }

    private func finish(timedOut: Bool) {
        guard running else { return }
        running = false
        watchdog?.cancel()
        watchdog = nil
        let renderSeconds = CFAbsoluteTimeGetCurrent() - startedAt
        let completion = self.completion
        self.completion = nil

        var playbackNote: String?
        if shouldPlay, !buffers.isEmpty {
            playbackNote = playCollected()
        }
        let report = buildReport(renderSeconds: renderSeconds, timedOut: timedOut, playbackNote: playbackNote)
        buffers = []
        completion?(report)
    }

    // MARK: - Playback (probe queue)

    /// Returns a failure description, or nil when playback started.
    private func playCollected() -> String? {
        guard let format = buffers.first?.format else { return "no buffers to play" }
        if !attached {
            engine.attach(player)
            attached = true
        }
        if connectedFormat == nil || connectedFormat?.sampleRate != format.sampleRate
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
        for buffer in buffers where buffer.format.sampleRate == format.sampleRate {
            player.scheduleBuffer(buffer, at: nil, options: [])
        }
        player.play()
        return nil
    }

    // MARK: - Analysis

    private func buildReport(renderSeconds: Double, timedOut: Bool, playbackNote: String?) -> Report {
        var lines: [String] = ["Voice: \(voiceLabel)."]

        guard let first = buffers.first else {
            let why = timedOut
                ? "No buffers within \(Int(watchdogSeconds)) seconds — the voice did not render."
                : "The voice returned no audio buffers."
            lines.append(why)
            if rejectedBuffers > 0 {
                lines.append("Buffers we could not read: \(rejectedBuffers).")
            }
            lines.append("Offline rendering is unavailable for this voice — pause trimming cannot work here.")
            return Report(headline: "Render failed: no audio", lines: lines)
        }

        let sampleRate = first.format.sampleRate
        let mono = Self.monoMixdown(buffers)
        let audioSeconds = Double(mono.count) / sampleRate
        let pauses = detectPauses(in: mono, sampleRate: sampleRate)
        let pauseTotal = pauses.reduce(0, +)
        let trailing = trailingSilenceSeconds(in: mono, sampleRate: sampleRate)

        lines.append("Buffers: \(buffers.count) (\(emptyBuffers) empty, \(rejectedBuffers) unreadable).")
        lines.append("Format: \(Int(sampleRate)) hertz, \(first.format.channelCount) channel, \(Self.formatName(first.format.commonFormat)).")
        lines.append("Audio length: \(Self.ms(audioSeconds)).")
        lines.append("Render time: \(Self.ms(renderSeconds)) — \(Self.speedRatio(audio: audioSeconds, render: renderSeconds)) times real time.")
        lines.append("Pauses over 60 milliseconds: \(pauses.count), totalling \(Self.ms(pauseTotal)) — \(Self.percent(pauseTotal, of: audioSeconds)) of the audio.")
        if !pauses.isEmpty {
            let listed = pauses.prefix(12).map { String(Int($0 * 1000)) }.joined(separator: ", ")
            lines.append("Pause lengths in milliseconds: \(listed).")
            lines.append("Longest pause: \(Self.ms(pauses.max() ?? 0)).")
        }
        lines.append("Trailing silence: \(Self.ms(trailing)).")
        if timedOut {
            lines.append("Note: the voice never signalled completion; results are what arrived within \(Int(watchdogSeconds)) seconds.")
        }
        if let playbackNote {
            lines.append("Playback failed: \(playbackNote).")
        } else if shouldPlay {
            lines.append("Playback: buffers scheduled on the app's own engine, unmodified.")
        }

        // What a first trimming pass would actually buy, before building it.
        let kept = pauses.reduce(0.0) { $0 + max($1 * 0.3, 0.030) } + max(trailing * 0.3, 0.030)
        let saved = max(pauseTotal + trailing - kept, 0)
        lines.append("At 30 percent with a 30 millisecond floor this phrase would shrink by \(Self.ms(saved)) of \(Self.ms(audioSeconds)).")

        return Report(
            headline: "Rendered \(buffers.count) buffers, \(pauses.count) pauses, \(Self.ms(pauseTotal)) of silence",
            lines: lines
        )
    }

    /// Silence runs, in seconds, ignoring the trailing one (that is the
    /// utterance tail, reported separately — it is what IBMTTS's "shorten at
    /// end of text only" mode targets).
    private func detectPauses(in mono: [Float], sampleRate: Double) -> [Double] {
        let windowFrames = max(Int(sampleRate * windowSeconds), 1)
        let quiet = quietWindows(in: mono, windowFrames: windowFrames)
        var pauses: [Double] = []
        var run = 0
        for isQuiet in quiet {
            if isQuiet {
                run += 1
                continue
            }
            appendRun(run, windowFrames: windowFrames, sampleRate: sampleRate, to: &pauses)
            run = 0
        }
        // A run reaching the end is the tail, not an interior pause, so the
        // final `run` is deliberately dropped.
        return pauses
    }

    private func appendRun(
        _ run: Int,
        windowFrames: Int,
        sampleRate: Double,
        to pauses: inout [Double]
    ) {
        guard run > 0 else { return }
        let seconds = Double(run * windowFrames) / sampleRate
        if seconds >= minPauseSeconds {
            pauses.append(seconds)
        }
    }

    private func trailingSilenceSeconds(in mono: [Float], sampleRate: Double) -> Double {
        let windowFrames = max(Int(sampleRate * windowSeconds), 1)
        let quiet = quietWindows(in: mono, windowFrames: windowFrames)
        var run = 0
        for isQuiet in quiet.reversed() {
            guard isQuiet else { break }
            run += 1
        }
        return Double(run * windowFrames) / sampleRate
    }

    private func quietWindows(in mono: [Float], windowFrames: Int) -> [Bool] {
        guard windowFrames > 0, !mono.isEmpty else { return [] }
        var result: [Bool] = []
        result.reserveCapacity(mono.count / windowFrames + 1)
        var start = 0
        while start < mono.count {
            let end = min(start + windowFrames, mono.count)
            var sum: Float = 0
            for index in start..<end {
                sum += mono[index] * mono[index]
            }
            let rms = (sum / Float(end - start)).squareRoot()
            result.append(rms < silenceThreshold)
            start = end
        }
        return result
    }

    // MARK: - Buffer helpers

    /// Copies any PCM buffer into a standard non-interleaved float buffer.
    /// Apple's TTS hands back int16 for several voices, and
    /// `AVAudioPlayerNode` insists on the format its connection was made
    /// with, so normalising once here removes both problems.
    private static func floatCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let source = buffer.format
        let frames = Int(buffer.frameLength)
        let channels = Int(source.channelCount)
        guard frames > 0, channels > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: source.sampleRate, channels: source.channelCount),
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

    private static func monoMixdown(_ buffers: [AVAudioPCMBuffer]) -> [Float] {
        var mono: [Float] = []
        for buffer in buffers {
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0, let data = buffer.floatChannelData else { continue }
            mono.reserveCapacity(mono.count + frames)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += data[channel][frame]
                }
                mono.append(sum / Float(channels))
            }
        }
        return mono
    }

    // MARK: - Formatting (spoken aloud, so: words, not symbols)

    private static func ms(_ seconds: Double) -> String {
        "\(Int((seconds * 1000).rounded())) milliseconds"
    }

    private static func percent(_ part: Double, of whole: Double) -> String {
        guard whole > 0 else { return "0 percent" }
        return "\(Int((part / whole * 100).rounded())) percent"
    }

    private static func speedRatio(audio: Double, render: Double) -> String {
        guard render > 0 else { return "an unknown number of" }
        return String(format: "%.1f", audio / render)
    }

    private static func formatName(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "32 bit float"
        case .pcmFormatFloat64: return "64 bit float"
        case .pcmFormatInt16: return "16 bit integer"
        case .pcmFormatInt32: return "32 bit integer"
        case .otherFormat: return "non-PCM"
        @unknown default: return "unknown"
        }
    }
}
