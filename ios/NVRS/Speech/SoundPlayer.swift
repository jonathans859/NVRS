import AVFoundation

/// Plays bundled copies of NVDA's earcons (browseMode, focusMode, error,
/// …) when the PC reports playing them. Unknown names are ignored — the
/// actual files live on the PC and only known sounds ship in the bundle.
final class SoundPlayer {
    private var players: [String: AVAudioPlayer] = [:]

    /// Only sane resource names reach the bundle lookup.
    private static let nameAllowed = CharacterSet.alphanumerics

    func play(_ name: String) {
        guard name.unicodeScalars.allSatisfy({ Self.nameAllowed.contains($0) }) else { return }
        if let player = players[name] {
            player.currentTime = 0
            player.play()
            return
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav")
            ?? Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Sounds")
        else { return }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.prepareToPlay()
        players[name] = player
        player.play()
    }
}
