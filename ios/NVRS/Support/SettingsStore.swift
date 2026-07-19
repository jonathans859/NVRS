import AVFoundation
import Foundation

struct NotificationFilter: Identifiable, Codable, Equatable {
    var id = UUID()
    var pattern: String
    var isRegex = false
    var isEnabled = true
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

    /// Experimental: inject Eloquence `p1 inline commands to shorten
    /// pauses, mirroring the NVDA IBMTTS driver's "Shorten all pauses".
    @Published var shortenPauses: Bool {
        didSet { defaults.set(shortenPauses, forKey: "shortenPauses") }
    }

    @Published var filters: [NotificationFilter] {
        didSet {
            if let data = try? JSONEncoder().encode(filters) {
                defaults.set(data, forKey: "filters")
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
        shortenPauses = defaults.object(forKey: "shortenPauses") as? Bool ?? false
        if let data = defaults.data(forKey: "filters"),
           let stored = try? JSONDecoder().decode([NotificationFilter].self, from: data) {
            filters = stored
        } else {
            filters = []
        }
    }

    var voiceDisplayName: String {
        guard let id = voiceIdentifier,
              let voice = AVSpeechSynthesisVoice(identifier: id)
        else { return String(localized: "System default") }
        return voice.name
    }
}
