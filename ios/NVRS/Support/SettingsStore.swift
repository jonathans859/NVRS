import AVFoundation
import Foundation

/// A PC-side voice observed in synthConfig messages, optionally mapped to
/// a specific iPhone voice.
struct PCVoice: Identifiable, Codable, Equatable {
    var key: String // "<synth>|<voice id>"
    var label: String // e.g. "German (ibmeci)"
    var lang: String?
    var phoneVoiceId: String?

    var id: String { key }
}

/// All user settings. UserDefaults-backed except the shared secret, which
/// lives in the keychain.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    @Published var host: String {
        didSet { defaults.set(host, forKey: "host") }
    }

    @Published var port: Int {
        didSet { defaults.set(port, forKey: "port") }
    }

    @Published var secret: String {
        didSet { KeychainHelper.saveSecret(secret) }
    }

    @Published var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: "autoConnect") }
    }

    /// Keep rendering (silence) while connected so iOS doesn't suspend the
    /// app in the background between utterances — the pocket use case.
    @Published var keepAliveInBackground: Bool {
        didSet { defaults.set(keepAliveInBackground, forKey: "keepAliveInBackground") }
    }

    @Published var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }

    /// Phone-side baselines that NVDA's relative prosody offsets apply to.
    @Published var baseRate: Double {
        didSet { defaults.set(baseRate, forKey: "baseRate") }
    }

    @Published var basePitch: Double {
        didSet { defaults.set(basePitch, forKey: "basePitch") }
    }

    @Published var baseVolume: Double {
        didSet { defaults.set(baseVolume, forKey: "baseVolume") }
    }

    /// Eloquence-style pause shortening, in the IBMTTS driver's own three
    /// modes. Off by default: it takes speech off AVSpeechSynthesizer's own
    /// playback path onto ours.
    @Published var pauseMode: PauseMode {
        didSet { defaults.set(pauseMode.rawValue, forKey: "pauseMode") }
    }

    /// Fraction of each pause that survives shortening.
    @Published var pauseFactor: Double {
        didSet { defaults.set(pauseFactor, forKey: "pauseFactor") }
    }

    /// Longest utterance still worth rendering for shortening. Beyond it the
    /// text goes to the system path instead — unshortened, and on a
    /// different output path, so audibly louder. In the field because the
    /// right ceiling depends on the device and the voice.
    @Published var pauseCharacterLimit: Int {
        didSet { defaults.set(pauseCharacterLimit, forKey: "pauseCharacterLimit") }
    }

    /// Switch the phone voice when the PC synth/voice changes, using the
    /// mapping table (or same-language auto pick when unmapped).
    @Published var followPCVoice: Bool {
        didSet { defaults.set(followPCVoice, forKey: "followPCVoice") }
    }

    /// Track the PC's NVDA rate instead of the local rate slider.
    @Published var followPCRate: Bool {
        didSet { defaults.set(followPCRate, forKey: "followPCRate") }
    }

    /// How many spoken lines the log keeps. The oldest fall off the end.
    @Published var speechLogLimit: Int {
        didSet { defaults.set(speechLogLimit, forKey: "speechLogLimit") }
    }

    /// PC voices seen so far, with optional per-voice phone mappings.
    @Published var pcVoices: [PCVoice] {
        didSet {
            if let data = try? JSONEncoder().encode(pcVoices) {
                defaults.set(data, forKey: "pcVoices")
            }
        }
    }

    private init() {
        host = defaults.string(forKey: "host") ?? ""
        let storedPort = defaults.integer(forKey: "port")
        port = storedPort == 0 ? 6877 : storedPort
        secret = KeychainHelper.loadSecret()
        autoConnect = defaults.object(forKey: "autoConnect") as? Bool ?? true
        keepAliveInBackground = defaults.object(forKey: "keepAliveInBackground") as? Bool ?? true
        voiceIdentifier = defaults.string(forKey: "voiceIdentifier")
        baseRate = defaults.object(forKey: "baseRate") as? Double
            ?? Double(AVSpeechUtteranceDefaultSpeechRate)
        basePitch = defaults.object(forKey: "basePitch") as? Double ?? 1.0
        baseVolume = defaults.object(forKey: "baseVolume") as? Double ?? 1.0
        pauseMode = PauseMode(rawValue: defaults.integer(forKey: "pauseMode")) ?? .off
        pauseFactor = defaults.object(forKey: "pauseFactor") as? Double ?? 0.3
        let storedLimit = defaults.integer(forKey: "pauseCharacterLimit")
        pauseCharacterLimit = storedLimit == 0 ? 2000 : storedLimit
        followPCVoice = defaults.object(forKey: "followPCVoice") as? Bool ?? true
        followPCRate = defaults.object(forKey: "followPCRate") as? Bool ?? true
        let storedLogLimit = defaults.integer(forKey: "speechLogLimit")
        speechLogLimit = storedLogLimit == 0 ? 50 : storedLogLimit
        if let data = defaults.data(forKey: "pcVoices"),
           let stored = try? JSONDecoder().decode([PCVoice].self, from: data) {
            pcVoices = stored
        } else {
            pcVoices = []
        }
    }

    /// Back to the shipped defaults for the three sliders — the way out of a
    /// voice you can barely understand, without hunting for the right values.
    func resetSpeechBaselines() {
        baseRate = Double(AVSpeechUtteranceDefaultSpeechRate)
        basePitch = 1.0
        baseVolume = 1.0
    }

    var voiceDisplayName: String {
        guard let id = voiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: id)
        else { return String(localized: "System default") }
        return voice.name
    }
}
