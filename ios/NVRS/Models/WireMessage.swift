import Foundation

/// Wire format: see PROTOCOL.md at the repo root. One JSON object per line.

enum SpeechPriorityLevel: String, Decodable {
    case normal
    case next
    case now
}

struct SpeechEnvelope: Decodable {
    let seq: Int
    let priority: SpeechPriorityLevel
    let ts: Double
    let items: [WireItem]

    /// Plain text of the envelope, for the transcript line and notification filters.
    var plainText: String {
        var parts: [String] = []
        for item in items {
            switch item {
            case .text(let value):
                parts.append(value)
            case .phoneme(_, let fallback):
                if let fallback { parts.append(fallback) }
            default:
                break
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SynthConfig: Decodable {
    let synth: String
    let voice: String?
    let voiceName: String?
    let lang: String?
    let rate: Int?
    let pitch: Int?
    let volume: Int?
}

enum WireItem: Decodable {
    case text(String)
    case pitch(offset: Int, multiplier: Double?)
    case rate(offset: Int, multiplier: Double?)
    case volume(offset: Int, multiplier: Double?)
    case lang(String?)
    case characterMode(Bool)
    case pause(ms: Int)
    case phoneme(ipa: String, fallback: String?)
    case index(Int)
    case endUtterance
    case beep(hz: Double, ms: Double, left: Double, right: Double)
    /// Forward compatibility: unknown item types are ignored, not fatal.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, value, offset, multiplier, lang, on, ms, ipa, text, index, hz, left, right
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(try c.decode(String.self, forKey: .value))
        case "pitch":
            self = .pitch(
                offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                multiplier: try c.decodeIfPresent(Double.self, forKey: .multiplier)
            )
        case "rate":
            self = .rate(
                offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                multiplier: try c.decodeIfPresent(Double.self, forKey: .multiplier)
            )
        case "volume":
            self = .volume(
                offset: try c.decodeIfPresent(Int.self, forKey: .offset) ?? 0,
                multiplier: try c.decodeIfPresent(Double.self, forKey: .multiplier)
            )
        case "lang":
            self = .lang(try c.decodeIfPresent(String.self, forKey: .lang))
        case "characterMode":
            self = .characterMode(try c.decodeIfPresent(Bool.self, forKey: .on) ?? false)
        case "break":
            self = .pause(ms: try c.decodeIfPresent(Int.self, forKey: .ms) ?? 0)
        case "phoneme":
            self = .phoneme(
                ipa: try c.decodeIfPresent(String.self, forKey: .ipa) ?? "",
                fallback: try c.decodeIfPresent(String.self, forKey: .text)
            )
        case "index":
            self = .index(try c.decodeIfPresent(Int.self, forKey: .index) ?? 0)
        case "endUtterance":
            self = .endUtterance
        case "beep":
            self = .beep(
                hz: try c.decodeIfPresent(Double.self, forKey: .hz) ?? 440,
                ms: try c.decodeIfPresent(Double.self, forKey: .ms) ?? 40,
                left: try c.decodeIfPresent(Double.self, forKey: .left) ?? 50,
                right: try c.decodeIfPresent(Double.self, forKey: .right) ?? 50
            )
        default:
            self = .unknown
        }
    }
}

enum ServerMessage {
    case speech(SpeechEnvelope)
    case cancel
    case synthConfig(SynthConfig)
    /// A standalone beep (progress bars, add-on sounds) outside any
    /// speech sequence; played immediately, not queued behind speech.
    case beep(hz: Double, ms: Double, left: Double, right: Double)
    case unknown
}

private struct BeepMessage: Decodable {
    let hz: Double?
    let ms: Double?
    let left: Double?
    let right: Double?
}

enum WireParser {
    private struct Probe: Decodable {
        let type: String?
    }

    private static let decoder = JSONDecoder()

    /// Parses one NDJSON line. Envelopes have no top-level "type";
    /// control messages do.
    static func parse(_ data: Data) -> ServerMessage? {
        guard let probe = try? decoder.decode(Probe.self, from: data) else { return nil }
        switch probe.type {
        case nil:
            return (try? decoder.decode(SpeechEnvelope.self, from: data)).map { .speech($0) }
        case "cancel":
            return .cancel
        case "synthConfig":
            return (try? decoder.decode(SynthConfig.self, from: data)).map { .synthConfig($0) }
        case "beep":
            return (try? decoder.decode(BeepMessage.self, from: data)).map {
                .beep(hz: $0.hz ?? 440, ms: $0.ms ?? 40, left: $0.left ?? 50, right: $0.right ?? 50)
            }
        default:
            return .unknown
        }
    }
}
