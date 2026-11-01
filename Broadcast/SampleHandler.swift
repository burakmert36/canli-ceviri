import ReplayKit
import CoreMedia

/// Ekran yayını uzantısı: telefonda çalan sesi (TikTok, YouTube vb.) yakalar
/// ve 16 kHz mono PCM olarak yerel bağlantı (127.0.0.1) üzerinden ana uygulamaya yollar.
/// Görüntü kareleri yok sayılır; hiçbir şey kaydedilmez veya internete gönderilmez.
final class SampleHandler: RPBroadcastSampleHandler {
    private var sender: AudioSender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let s = AudioSender()
        s.onFinish = { [weak self] message in
            let err = NSError(domain: "CanliCeviri", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            self?.finishBroadcastWithError(err)
        }
        s.start()
        sender = s
    }

    override func broadcastPaused() {}
    override func broadcastResumed() {}

    override func broadcastFinished() {
        sender?.stop()
        sender = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .audioApp else { return }
        sender?.process(sampleBuffer)
    }
}
