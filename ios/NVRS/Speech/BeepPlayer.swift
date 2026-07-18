import AVFoundation

/// Plays NVDA's beep commands (e.g. capital-letter beeps) as short sine
/// tones. Best effort: if the engine won't start, beeps are dropped.
final class BeepPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    private var configured = false

    private func ensureRunning() -> Bool {
        if !configured {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return false
            }
        }
        return true
    }

    func play(hz: Double, ms: Double, pan: Float) {
        guard hz > 0, ms > 0, ensureRunning() else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let frameCount = AVAudioFrameCount(sampleRate * ms / 1000.0)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount
        // 5 ms fade at each end avoids clicks.
        let fadeFrames = min(Int(sampleRate * 0.005), Int(frameCount) / 2)
        for frame in 0..<Int(frameCount) {
            var amplitude: Float = 0.5
            if frame < fadeFrames {
                amplitude *= Float(frame) / Float(fadeFrames)
            } else if frame >= Int(frameCount) - fadeFrames {
                amplitude *= Float(Int(frameCount) - frame) / Float(fadeFrames)
            }
            samples[frame] = amplitude * Float(sin(2.0 * .pi * hz * Double(frame) / sampleRate))
        }
        player.pan = min(max(pan, -1), 1)
        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()
    }
}
