import Foundation
import AVFoundation

/// Uygulamanın arka planda (kutu açıkken) çalışmaya devam etmesi için ses oturumunu açık tutar.
/// Sessiz bir döngü çalar; diğer uygulamaların sesiyle karışır, onları kısmaz/durdurmaz.
final class KeepAlive: NSObject {
    private var player: AVAudioPlayer?

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        if player == nil {
            let silence = Chunker.wav([Int16](repeating: 0, count: 8000), rate: 8000)
            let p = try AVAudioPlayer(data: silence)
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            player = p
        }
        player?.play()
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaReset(_:)),
                                               name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    @objc private func mediaReset(_ n: Notification) {
        player = nil
        try? start()
    }
}
