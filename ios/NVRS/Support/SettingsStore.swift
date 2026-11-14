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

/// A PC address the user saved to switch back to later.
struct SavedConnection: Identifiable, Codable, Equatable {
    var host: String
    var port: Int
    /// Optional friendly name ("PC"). Optional so lists saved before names
    /// existed still decode.
    var name: String?

    /// Also the keychain key for the connection's secret, so it stays
    /// address-based whatever the name.
    var id: String { "\(host):\(port)" }

    var displayName: String { name ?? id }
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
        didSet {
            KeychainHelper.saveSecret(secret)
            // Editing the secret while a saved connection is selected
            // updates that connection's copy too.
            if let current = savedConnections.first(where: isCurrent) {
                KeychainHelper.saveSecret(secret, forConnection: current.id)
            }
        }
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

    /// Addresses saved under Connection; picking one fills host and port.
    @Published var savedConnections: [SavedConnection] {
        didSet {
            if let data = try? JSONEncoder().encode(savedConnections) {
                defaults.set(data, forKey: "savedConnections")
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
        if let data = defaults.data(forKey: "savedConnections"),
           let stored = try? JSONDecoder().decode([SavedConnection].self, from: data) {
            savedConnections = stored
        } else {
            savedConnections = []
        }
    }

    /// The host and port currently in the fields, trimmed, or nil when they
    /// are empty, out of range or already saved.
    var connectionToSave: SavedConnection? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, port > 0, port <= 65535 else { return nil }
        let candidate = SavedConnection(host: trimmed, port: port)
        return savedConnections.contains { $0.id == candidate.id } ? nil : candidate
    }

    func isCurrent(_ connection: SavedConnection) -> Bool {
        connection.host == host.trimmingCharacters(in: .whitespacesAndNewlines)
            && connection.port == port
    }

    /// Saves host, port and secret as they are in the fields now. The
    /// secret goes to the keychain under the connection's `ip:port`.
    func saveCurrentConnection(name: String) -> SavedConnection? {
        guard var connection = connectionToSave else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.name = trimmedName.isEmpty ? nil : trimmedName
        KeychainHelper.saveSecret(secret, forConnection: connection.id)
        savedConnections.append(connection)
        return connection
    }

    func select(_ connection: SavedConnection) {
        host = connection.host
        port = connection.port
        secret = KeychainHelper.loadSecret(forConnection: connection.id)
    }

    func deleteSavedConnections(atOffsets offsets: IndexSet) {
        for index in offsets {
            KeychainHelper.deleteSecret(forConnection: savedConnections[index].id)
        }
        savedConnections.remove(atOffsets: offsets)
    }

    func deleteSavedConnection(_ connection: SavedConnection) {
        guard let index = savedConnections.firstIndex(of: connection) else { return }
        deleteSavedConnections(atOffsets: IndexSet(integer: index))
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
