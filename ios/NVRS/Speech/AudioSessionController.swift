import AVFoundation
import Foundation

#if os(macOS)

/// macOS has no AVAudioSession and no app suspension: audio always plays,
/// the process keeps running, and nothing ducks. Same surface as the iOS
/// controller so the view model stays platform-free; every call is a no-op.
@MainActor
final class AudioSessionController {
    private(set) var lastError: String?
    var isRendererIdle: (() -> Bool)?
    var startSilentEngine: (() -> Void)?
    var stopSilentEngine: (() -> Void)?

    func setKeepAliveWanted(_ wanted: Bool) {}
    func speechActivity() {}
    func rendererBecameIdle() {}
    func shutdown() {}
}

#else

/// Manages the playback session across three modes:
///
/// - `speaking`: mirrored speech is flowing — low-latency IO buffer. Mixes
///   with other audio like idle mode does; only the buffer differs.
/// - `idleKeepAlive`: connected but quiet — session stays active and a
///   silent engine keeps rendering so iOS doesn't suspend the app (the
///   pocket use case). No ducking, and a long IO buffer (~10 wakeups/s)
///   keeps the battery cost low.
/// - `inactive`: not connected or keep-alive disabled — session released.
@MainActor
final class AudioSessionController {
    private enum Mode {
        case inactive
        case idleKeepAlive
        case speaking
    }

    /// How long after the last speech before dropping back to idle mode.
    private let idleGraceSeconds: TimeInterval = 120
    private let speakingBufferDuration: TimeInterval = 0.02
    private let idleBufferDuration: TimeInterval = 0.1

    private var mode: Mode = .inactive
    private var keepAliveWanted = false
    private var idleWork: DispatchWorkItem?

    /// Last activation failure, for the diagnostics UI. Nil when healthy.
    private(set) var lastError: String?

    /// True while the renderer still has queued work; checked before lapsing.
    var isRendererIdle: (() -> Bool)?

    /// Start/stop the silent rendering engine (the renderer's beep engine
    /// doubles as it); set by the view model.
    var startSilentEngine: (() -> Void)?
    var stopSilentEngine: (() -> Void)?

    /// Keep-alive intent: on while the user wants a connection and the
    /// setting is enabled. Holds the app alive in background to receive
    /// and reconnect.
    func setKeepAliveWanted(_ wanted: Bool) {
        keepAliveWanted = wanted
        if wanted {
            if mode == .inactive {
                enterIdleKeepAlive()
            } else if mode == .speaking {
                startSilentEngine?()
            }
        } else if mode == .idleKeepAlive {
            deactivate()
        }
    }

    func speechActivity() {
        idleWork?.cancel()
        idleWork = nil
        enterSpeaking()
    }

    func rendererBecameIdle() {
        scheduleIdleLapse()
    }

    func shutdown() {
        idleWork?.cancel()
        idleWork = nil
        keepAliveWanted = false
        deactivate()
    }

    // MARK: - Mode transitions

    private func configure(
        options: AVAudioSession.CategoryOptions,
        bufferDuration: TimeInterval
    ) -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: options)
            try? session.setPreferredIOBufferDuration(bufferDuration)
            try session.setActive(true)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func enterSpeaking() {
        guard mode != .speaking else { return }
        // Mix, never duck (field-requested 2026-08-19). Ducking outlived the
        // speech that caused it: the session only lapses back to idle
        // options 120s after the renderer goes quiet, and a working NVDA
        // session refreshes that timer constantly — so the duck was
        // effectively permanent. Fallback ladder: never end up silent on
        // the default session.
        let ok = configure(options: [.mixWithOthers], bufferDuration: speakingBufferDuration)
            || configure(options: [], bufferDuration: speakingBufferDuration)
        if ok {
            mode = .speaking
            if keepAliveWanted {
                startSilentEngine?()
            }
        }
    }

    private func enterIdleKeepAlive() {
        guard keepAliveWanted else {
            deactivate()
            return
        }
        guard mode != .idleKeepAlive else { return }
        // Mix, don't duck: idling must not squash the user's music.
        let ok = configure(options: [.mixWithOthers], bufferDuration: idleBufferDuration)
            || configure(options: [], bufferDuration: idleBufferDuration)
        if ok {
            mode = .idleKeepAlive
            startSilentEngine?()
        }
    }

    private func scheduleIdleLapse() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRendererIdle?() ?? true else { return }
            self.enterIdleKeepAlive()
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleGraceSeconds, execute: work)
    }

    private func deactivate() {
        stopSilentEngine?()
        guard mode != .inactive else { return }
        mode = .inactive
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

#endif
