import AVFoundation
import Foundation

/// Short, quiet system sounds for start / stop / error. Loading and playback happen on a
/// background queue, so calling these never blocks the caller (or a recording that's starting).
enum Sounds {
    private static let volume: Float = 0.3
    private static let queue = DispatchQueue(label: "64Voice.sounds", qos: .userInitiated)
    /// Confined to `queue`.
    nonisolated(unsafe) private static var players: [String: AVAudioPlayer] = [:]

    private static let startName = "Tink"
    private static let stopName = "Pop"
    private static let errorName = "Basso"

    @MainActor static func playStart() { play(startName) }
    @MainActor static func playStop() { play(stopName) }
    @MainActor static func playError() { play(errorName) }

    /// Optional: loads all sounds ahead of time (otherwise the first play of each loads it).
    static func preload() {
        queue.async {
            for name in [startName, stopName, errorName] { _ = player(named: name) }
        }
    }

    @MainActor private static func play(_ name: String) {
        guard AppSettings.shared.playSounds else { return }
        queue.async {
            guard let player = player(named: name) else { return }
            player.currentTime = 0
            player.play()
        }
    }

    private static func player(named name: String) -> AVAudioPlayer? {
        if let player = players[name] { return player }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.volume = volume
        player.prepareToPlay()
        players[name] = player
        return player
    }
}
