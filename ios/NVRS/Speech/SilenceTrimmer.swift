import AVFoundation
import Foundation

/// The IBMTTS driver's three modes, with its numbering, so the vocabulary
/// matches what Eloquence users on Windows already know.
enum PauseMode: Int, CaseIterable, Identifiable {
    case off = 0
    case ends = 1
    case all = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off: return String(localized: "Do not shorten")
        case .ends: return String(localized: "Shorten at utterance ends only")
        case .all: return String(localized: "Shorten all pauses")
        }
    }
}

/// Finds silence in rendered speech and shortens it.
///
/// This is the whole point of the offline-render route: text, punctuation,
/// voice, intonation and word timing are untouched — only the gaps get
/// shorter, and proportionally, so a long pause stays longer than a short
/// one. Every earlier attempt edited the text or moved utterance
/// boundaries and was rejected for it; see
/// `.claude-notes/pause-shortening-ios-v4.md`.
///
/// Cuts always land *inside* a silent run (we keep its first frames and skip
/// the rest), so both sides of a splice are below the silence threshold and
/// no fade is needed.
struct SilenceTrimmer {
    /// Below this a window counts as silence. In dB rather than at zero,
    /// because neural voices have a noise floor where ECI has true digital
    /// silence.
    var thresholdDB: Double = -50
    var windowSeconds: Double = 0.005
    /// Shorter gaps are coarticulation, not pauses; shortening them slurs.
    var minPauseSeconds: Double = 0.040
    /// A shortened pause never drops below this — pauses of zero run words
    /// together.
    var floorSeconds: Double = 0.025

    struct Pause {
        var startFrame: Int
        var frames: Int
        var seconds: Double
        var isLeading: Bool
        var isTrailing: Bool
    }

    struct Analysis {
        var totalSeconds: Double = 0
        var pauses: [Pause] = []
        var leadingSeconds: Double = 0
        var trailingSeconds: Double = 0
        var interiorSeconds: Double = 0
        /// Median level of the quiet windows. Near the threshold means the
        /// threshold, not the voice, is deciding what counts as a pause.
        var noiseFloorDB: Double = -.infinity
    }

    // MARK: - Analysis

    func analyze(_ buffer: AVAudioPCMBuffer) -> Analysis {
        let sampleRate = buffer.format.sampleRate
        let totalFrames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard totalFrames > 0, channels > 0, sampleRate > 0,
              let data = buffer.floatChannelData
        else { return Analysis() }

        let windowFrames = max(Int(sampleRate * windowSeconds), 1)
        let threshold = pow(10.0, thresholdDB / 20.0)
        var quiet: [Bool] = []
        var quietLevels: [Double] = []
        quiet.reserveCapacity(totalFrames / windowFrames + 1)

        var start = 0
        while start < totalFrames {
            let end = min(start + windowFrames, totalFrames)
            var sum = 0.0
            for channel in 0..<channels {
                let samples = data[channel]
                for index in start..<end {
                    let value = Double(samples[index])
                    sum += value * value
                }
            }
            let rms = (sum / Double((end - start) * channels)).squareRoot()
            let isQuiet = rms < threshold
            quiet.append(isQuiet)
            if isQuiet { quietLevels.append(rms) }
            start = end
        }

        var analysis = Analysis()
        analysis.totalSeconds = Double(totalFrames) / sampleRate
        analysis.noiseFloorDB = Self.medianDB(of: quietLevels)

        let minFrames = Int(minPauseSeconds * sampleRate)
        var runStart: Int?

        func closeRun(endWindow: Int) {
            guard let begin = runStart else { return }
            runStart = nil
            let startFrame = begin * windowFrames
            let frames = min(endWindow * windowFrames, totalFrames) - startFrame
            guard frames >= minFrames else { return }
            analysis.pauses.append(
                Pause(
                    startFrame: startFrame,
                    frames: frames,
                    seconds: Double(frames) / sampleRate,
                    isLeading: begin == 0,
                    isTrailing: endWindow == quiet.count
                )
            )
        }

        for (index, isQuiet) in quiet.enumerated() {
            if isQuiet {
                if runStart == nil { runStart = index }
            } else {
                closeRun(endWindow: index)
            }
        }
        closeRun(endWindow: quiet.count)

        for pause in analysis.pauses {
            if pause.isLeading {
                analysis.leadingSeconds += pause.seconds
            } else if pause.isTrailing {
                analysis.trailingSeconds += pause.seconds
            } else {
                analysis.interiorSeconds += pause.seconds
            }
        }
        return analysis
    }

    // MARK: - Trimming

    /// - Parameter factor: what fraction of each pause survives (0.3 = 30 %).
    ///
    /// `.ends` shortens the leading and trailing silence only. On the phone
    /// the seam between two utterances is trailing silence plus leading
    /// silence plus the queue hop, so both ends are what the driver's
    /// "shorten at end of text only" is really about.
    func trimmed(_ buffer: AVAudioPCMBuffer, mode: PauseMode, factor: Double) -> AVAudioPCMBuffer {
        guard mode != .off else { return buffer }
        let analysis = analyze(buffer)
        let targets = analysis.pauses.filter { mode == .all || $0.isLeading || $0.isTrailing }
        guard !targets.isEmpty, let source = buffer.floatChannelData else { return buffer }

        let sampleRate = buffer.format.sampleRate
        let floorFrames = Int(floorSeconds * sampleRate)
        let totalFrames = Int(buffer.frameLength)
        let clampedFactor = min(max(factor, 0), 1)

        var kept: [(start: Int, count: Int)] = []
        var cursor = 0
        for pause in targets {
            if pause.startFrame > cursor {
                kept.append((cursor, pause.startFrame - cursor))
            }
            let keep = min(max(Int(Double(pause.frames) * clampedFactor), floorFrames), pause.frames)
            if keep > 0 {
                kept.append((pause.startFrame, keep))
            }
            cursor = pause.startFrame + pause.frames
        }
        if cursor < totalFrames {
            kept.append((cursor, totalFrames - cursor))
        }

        let outputFrames = kept.reduce(0) { $0 + $1.count }
        guard outputFrames > 0, outputFrames < totalFrames,
              let output = AVAudioPCMBuffer(
                  pcmFormat: buffer.format,
                  frameCapacity: AVAudioFrameCount(outputFrames)
              ),
              let destination = output.floatChannelData
        else { return buffer }
        output.frameLength = AVAudioFrameCount(outputFrames)

        let channels = Int(buffer.format.channelCount)
        var write = 0
        for range in kept {
            for channel in 0..<channels {
                for offset in 0..<range.count {
                    destination[channel][write + offset] = source[channel][range.start + offset]
                }
            }
            write += range.count
        }
        return output
    }

    // MARK: - Helpers

    /// One buffer from many. The renderer delivers a few hundred small ones;
    /// everything downstream wants a single waveform.
    static func concatenated(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let destination = output.floatChannelData
        else { return nil }
        let channels = Int(format.channelCount)
        var write = 0
        for buffer in buffers {
            guard buffer.format.sampleRate == format.sampleRate,
                  buffer.format.channelCount == format.channelCount,
                  let source = buffer.floatChannelData
            else { continue }
            let frames = Int(buffer.frameLength)
            for channel in 0..<channels {
                for offset in 0..<frames {
                    destination[channel][write + offset] = source[channel][offset]
                }
            }
            write += frames
        }
        guard write > 0 else { return nil }
        output.frameLength = AVAudioFrameCount(write)
        return output
    }

    static func silence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(seconds * format.sampleRate)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<frames {
                data[channel][frame] = 0
            }
        }
        return buffer
    }

    private static func medianDB(of levels: [Double]) -> Double {
        guard !levels.isEmpty else { return -.infinity }
        let sorted = levels.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return -.infinity }
        return 20 * log10(median)
    }
}
