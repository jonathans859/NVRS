import AVFoundation

/// One `AVAudioEngine` for the whole app, shared by the beep player and the
/// trimmed speech player.
///
/// Two engines on one audio session fought over it — crackling, clipped
/// starts, and bursts that produced no sound at all. Worse, the speech player
/// used to stop its engine every time the queue drained, which for a screen
/// reader is between every burst: the restart cost the first buffer of the
/// next burst, and a player node left playing across an `engine.stop()` never
/// delivered its completion handlers again (which is why a probe run worked
/// once and then hung).
///
/// So: one engine, kept running while the app wants audio at all, and
/// stopping it always stops the player nodes first. Main-thread only.
final class AudioEngineHost {
    private let engine = AVAudioEngine()
    private var connected: [ObjectIdentifier: AVAudioFormat] = [:]
    private var nodes: [AVAudioPlayerNode] = []
    private var wantsRunning = false

    var isRunning: Bool { engine.isRunning }

    private var resetHandlers: [() -> Void] = []

    /// Called only when the engine actually went down and took its scheduled
    /// audio with it — so a handler firing means audio was lost and has to be
    /// played again, not merely that something in the session changed.
    func onAudioReset(_ handler: @escaping () -> Void) {
        resetHandlers.append(handler)
    }

    init() {
        // A route change (headphones, a call, the session reconfiguring its
        // IO buffer) stops the engine and drops its connections. Without this
        // the app just goes quiet until something restarts it.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
    }

    /// The engine stops *itself* on a configuration change, so a still-running
    /// engine means the graph survived and nothing needs disturbing. Only when
    /// it went down do we rebuild — and only then did anyone lose audio.
    private func rebuild() {
        guard wantsRunning, !engine.isRunning else { return }
        for node in nodes {
            guard let format = connected[ObjectIdentifier(node)] else { continue }
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        _ = start()
        for handler in resetHandlers {
            handler()
        }
    }

    /// Attaches the node once and connects it, reconnecting only when the
    /// format actually changes (a different voice's sample rate).
    func connect(_ node: AVAudioPlayerNode, format: AVAudioFormat) {
        let key = ObjectIdentifier(node)
        if let existing = connected[key] {
            guard existing.sampleRate != format.sampleRate
                || existing.channelCount != format.channelCount
            else { return }
        } else {
            engine.attach(node)
            nodes.append(node)
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        connected[key] = format
    }

    /// Returns a failure description, or nil when the engine is running.
    func start() -> String? {
        wantsRunning = true
        guard !engine.isRunning else { return nil }
        do {
            try engine.start()
            return nil
        } catch {
            return "engine start failed: \(error.localizedDescription)"
        }
    }

    /// Stops the player nodes first: a node left in its playing state across
    /// an engine stop comes back with its completion callbacks broken.
    func stop() {
        wantsRunning = false
        guard engine.isRunning else { return }
        for node in nodes {
            node.stop()
        }
        engine.stop()
    }
}
