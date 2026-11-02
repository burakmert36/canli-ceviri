import Foundation
import AVFoundation

/// Uygulamanın arka planda (kutu açıkken) çalışmaya devam etmesi için ses oturumunu açık tutar.
/// Sessiz bir döngü çalar; diğer uygulamaların sesiyle karışır, onları kısmaz/durdurmaz.
final class KeepAlive: NSObject {
    private var player: AVAudioPlayer?
    /// Diğer uygulamaların sesi şu an kısık mı?
    private(set) var ducking = false
    private var active = false

    private var options: AVAudioSession.CategoryOptions {
        ducking ? [.mixWithOthers, .duckOthers] : [.mixWithOthers]
    }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: options)
        try session.setActive(true)
        active = true
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
        active = false
        ducking = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        // Kısma ayarı bir sonraki oturuma taşınmasın.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    /// Diğer uygulamaların (YouTube vb.) sesini kısar ya da eski hâline getirir. Telefonun ses düzeyi değişmez;
    /// bizim seslendirmemiz tam seste kalır. iOS kısmayı ancak oturum yeniden etkinleşince uygular/kaldırır,
    /// bu yüzden oturum çok kısa süre kapatılıp yeniden açılır (sessiz oynatıcı hemen devam eder).
    func setDucking(_ on: Bool) {
        guard on != ducking else { return }
        ducking = on
        guard active else { return }
        let session = AVAudioSession.sharedInstance()
        let wasPlaying = player?.isPlaying ?? false
        player?.pause()
        try? session.setActive(false, options: on ? [] : .notifyOthersOnDeactivation)
        try? session.setCategory(.playback, mode: on ? .spokenAudio : .default, options: options)
        do {
            try session.setActive(true)
        } catch {
            // Etkinleşemezse kısmasız devam et (arka planda çalışmaya devam etmek daha önemli).
            ducking = false
            try? session.setCategory(.playback, mode: .default, options: options)
            try? session.setActive(true)
        }
        if wasPlaying || player != nil { player?.play() }
    }

    @objc private func interrupted(_ n: Notification) {
        guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended, active {
            try? AVAudioSession.sharedInstance().setActive(true)
            player?.play()
        }
    }

    @objc private func mediaReset(_ n: Notification) {
        player = nil
        try? start()
    }
}
