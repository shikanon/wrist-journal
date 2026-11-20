import AVFoundation
import SwiftUI

@MainActor
final class LocalPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    private var player: AVAudioPlayer?

    var position: TimeInterval { player?.currentTime ?? 0 }

    func seek(to time: TimeInterval) {
        if let player { player.currentTime = min(max(0, time), player.duration) }
    }

    func play(_ url: URL, startingAt time: TimeInterval = 0) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setActive(true)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.currentTime = min(max(0, time), player.duration)
            guard player.play() else { throw JournalError.playbackFailed }
            self.player = player
            playing = true
        } catch {
            try? session.setActive(false)
            throw error
        }
    }

    func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finish(ObjectIdentifier(player))
    }

    private nonisolated func finish(_ id: ObjectIdentifier) {
        Task { @MainActor in
            if let player = self.player, ObjectIdentifier(player) == id {
                stop()
            }
        }
    }
}
