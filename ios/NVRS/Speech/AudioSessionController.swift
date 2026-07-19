import AVFoundation
import Foundation

/// Holds an active playback session while speech is flowing, and lets it
/// lapse after a quiet stretch. Deliberately no keep-alive tricks: if NVDA
/// goes silent for a long time the app may be suspended, and the transport
/// reconnects cleanly on the next foreground.
@MainActor
final class AudioSessionController {
    /// How long the session is kept active after the last speech.
    private let idleGraceSeconds: TimeInterval = 120

    private var isActive = false
    private var idleWork: DispatchWorkItem?

    /// Last activation failure, for the diagnostics UI. Nil when healthy.
    private(set) var lastError: String?

    /// True while the renderer still has queued work; checked before lapsing.
    var isRendererIdle: (() -> Bool)?

    func speechActivity() {
        idleWork?.cancel()
        idleWork = nil
        activate()
    }

    func rendererBecameIdle() {
        scheduleIdleLapse()
    }

    func shutdown() {
        idleWork?.cancel()
        idleWork = nil
        deactivate()
    }

    private func activate() {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        // Preferred: duck music, pause podcasts/audiobooks while mirrored
        // speech plays. Fall back to plainer configurations rather than
        // ending up silent on the default (.soloAmbient) session.
        let optionSets: [AVAudioSession.CategoryOptions] = [
            [.duckOthers, .interruptSpokenAudioAndMixWithOthers],
            [.duckOthers],
            [],
        ]
        var failure: Error?
        for options in optionSets {
            do {
                try session.setCategory(.playback, mode: .spokenAudio, options: options)
                try session.setActive(true)
                isActive = true
                lastError = nil
                return
            } catch {
                failure = error
            }
        }
        if let failure {
            lastError = failure.localizedDescription
        }
    }

    private func scheduleIdleLapse() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRendererIdle?() ?? true else { return }
            self.deactivate()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleGraceSeconds, execute: work)
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
