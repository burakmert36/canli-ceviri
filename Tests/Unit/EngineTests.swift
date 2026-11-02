import XCTest
import UIKit
import AVFoundation
@testable import CanliCeviri

/// Uçtan uca: sahte yayın uzantısı (gerçek yerel bağlantı) → ekran okuma / ses → çeviri (sahte ağ) → kutu.
/// Uygulamanın gerçek Engine'i kullanılır; ayarlar test sonunda geri yüklenir.
final class EngineTests: XCTestCase {
    private let engine = Engine.shared
    private let s = AppSettings.shared
    private var client: TCPClient?
    private var savedDefaults: [String: Any] = [:]
    private let keys = ["inputSource", "translator", "displayMode", "sourceLang", "targetLang", "asr", "geminiKey",
                        "historyEnabled", "speakEnabled", "liveTranslation", "batteryMode", "ocrAreaMode",
                        "portraitArea", "landscapeArea", "recentPairs", "hybridLive", "lines", "contentKind", "claudeKey",
                        "duckMode"]

    override func setUp() {
        super.setUp()
        for k in keys { if let v = UserDefaults.standard.object(forKey: k) { savedDefaults[k] = v } }
        if engine.running { engine.stop() }
        StubNetwork.install()
        StubURLProtocol.setHandler { r, body in
            if r.url?.host == "translate.googleapis.com" {
                return StubNetwork.googleReply("TR(" + StubNetwork.googleQuery(r) + ")")
            }
            if r.url?.host == "generativelanguage.googleapis.com" {
                return StubURLProtocol.json(["candidates": [["content": ["parts": [
                    ["text": "{\"original\": \"hello world\", \"translation\": \"merhaba dünya\"}"],
                ]]]]])
            }
            return StubURLProtocol.json(["error": ["message": "unexpected"]], status: 500)
        }
        s.historyEnabled = false
        s.speakEnabled = false
        s.liveTranslation = true
        s.batteryMode = .off
        s.ocrAreaMode = .manual
        s.portraitArea = AppSettings.defaultPortraitArea
        s.landscapeArea = AppSettings.defaultLandscapeArea
        s.sourceLang = "en-US"
        s.targetLang = "tr"
        s.translator = .google
        s.displayMode = .both
        s.lines = 3
        engine.simulateBackground = true
        spin(0.4)   // ayar değişikliklerinin (250 ms gecikmeli) işlenmesi
        warmUpOnce()
    }

    private static var warmedUp = false

    /// Motorun ilk açılışı (ses oturumu, PiP, yazı tanıma modeli) simülatörde saniyeler sürebilir.
    /// Bu tek seferlik süre ilk testin zamanlamasına binmesin diye bir kez boşta çalıştırılır.
    private func warmUpOnce() {
        guard !Self.warmedUp else { return }
        Self.warmedUp = true
        let inputBefore = s.inputSource
        s.inputSource = .screen
        spin(0.4)
        guard let c = TCPClient(port: AudioReceiver.port, timeout: 10) else { return }
        c.startHeartbeat()
        _ = waitUntil(10) { self.engine.audioConnected }
        engine.start()
        sendRepeatedly(c, frame("Warm up line for the reader"), times: 3)
        engine.stop()
        spin(0.5)
        c.close()
        _ = waitUntil(10) { !self.engine.audioConnected }
        s.inputSource = inputBefore
        spin(0.4)
    }

    /// Hata iletisine eklenen kısa tanı: motor durumu ve bağlantı günlüğünün sonu.
    private func diag() -> String {
        "durum: \(engine.status) | günlük: " + ConnectionLog.shared.entries.suffix(8).joined(separator: " ¦ ")
    }

    override func tearDown() {
        if engine.running { engine.stop() }
        spin(0.3)
        client?.close()
        client = nil
        engine.simulateBackground = false
        StubNetwork.uninstall()
        let d = UserDefaults.standard
        for k in keys {
            if let v = savedDefaults[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    /// Uzantı gibi bağlanır.
    private func connectExtension(file: StaticString = #filePath, line: UInt = #line) -> TCPClient? {
        guard let c = TCPClient(port: AudioReceiver.port) else {
            XCTFail("Uygulamanın alıcısına bağlanılamadı", file: file, line: line)
            return nil
        }
        client = c
        c.startHeartbeat()   // gerçek uzantı gibi saniyede bir nabız
        XCTAssertTrue(waitUntil(5) { self.engine.audioConnected }, "Bağlantı algılanmadı", file: file, line: line)
        return c
    }

    private let pw = 600, ph = 1300

    /// Koşul sağlanana dek kareyi aralıklarla yollar. Gerçek yayında da yazı ekrandayken kare sürekli gelir;
    /// okuyucu meşgulken gelen kare atlanır, bu yüzden sabit sayıda kare yollamak yavaş makinede yetmeyebilir.
    @discardableResult
    private func sendUntil(_ c: TCPClient, _ data: Data, timeout: TimeInterval = 25, gap: TimeInterval = 0.5,
                           _ done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done() { return true }
            c.send(data)
            if waitUntil(gap, done) { return true }
        }
        return done()
    }

    /// Aynı kareyi birkaç kez yollar (okuyucu meşgulken gelen kare atlanır; gerçek yayında da kareler tekrar gelir).
    private func sendRepeatedly(_ c: TCPClient, _ data: Data, times: Int = 4, gap: TimeInterval = 0.6) {
        for _ in 0..<times {
            c.send(data)
            spin(gap)
        }
    }

    private func frame(_ caption: String?, title: String = "Video title stays here") -> Data {
        var texts: [(String, CGFloat)] = [(title, 0.45)]
        if let c = caption { texts.append((c, 0.29)) }
        return Wire.frame(width: pw, height: ph, orientation: 1, pixels: FakeScreen.gray(width: pw, height: ph, texts: texts))
    }

    // MARK: Ekran altyazısı

    func testScreenCaptionsAreReadTranslatedAndShown() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        XCTAssertTrue(engine.running, engine.status)
        // Uzantıya görüntü istendi ve ses kapatıldı (pil)
        let cmds = String(decoding: c.receive(timeout: 1), as: UTF8.self)
        XCTAssertTrue(cmds.contains("V"), "görüntü isteği: \(cmds)")
        XCTAssertTrue(cmds.contains("m"), "ses kapatma: \(cmds)")

        sendRepeatedly(c, frame(nil), times: 2)           // ilk kare: sabit yazılar öğrenilir
        sendUntil(c, frame("Hello my good friend")) { self.engine.shownOriginal.lowercased().contains("friend") }
        let ok = sendUntil(c, frame("my good friend how are you today")) {
            self.engine.shownOriginal.lowercased().contains("today") && self.engine.shownTranslation.contains("TR(")
        }
        XCTAssertTrue(ok, "orijinal: \(engine.shownOriginal) | çeviri: \(engine.shownTranslation) | \(diag())")
        XCTAssertFalse(engine.shownOriginal.lowercased().contains("title"), "Başlık alan dışında kalmalı")
        // Kayan altyazı tekrar etmemeli (kutuda son kesinleşen + canlı cümle görünür)
        let o = engine.shownOriginal.lowercased()
        XCTAssertLessThanOrEqual(o.components(separatedBy: "friend").count - 1, 1, "Tekrarlanan kelimeler: \(o)")
        XCTAssertFalse(o.contains("good friend my good"), "Tekrarlanan kelimeler: \(o)")
        XCTAssertEqual(o.components(separatedBy: "today").count - 1, 1, "Tekrarlanan kelimeler: \(o)")
    }

    func testOwnAppForegroundIsNotRead() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.simulateBackground = false
        engine.start()
        c.send(frame(nil)); spin(0.6)
        c.send(frame("This must not be read"))
        spin(3)
        XCTAssertFalse(engine.shownOriginal.lowercased().contains("must"), "Uygulama öndeyken kendi ekranı okunmamalı")
    }

    // MARK: Ses (bulut tanıma)

    func testCloudAudioPathEndToEnd() {
        s.inputSource = .audio
        s.asr = .gemini
        s.translator = .gemini
        s.geminiKey = "test-key"
        s.sourceLang = "auto"
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        XCTAssertTrue(engine.running, engine.status)
        // 4 sn konuşma benzeri ses + sessizlik
        let speech = Wire.sine(freq: 280, seconds: 4, amplitude: 0.3)
        for i in stride(from: 0, to: speech.count, by: 1600) {
            c.send(Wire.audio(Array(speech[i..<min(i + 1600, speech.count)])))
        }
        c.send(Wire.audio([Int16](repeating: 0, count: 16000)))
        let ok = waitUntil(20) { self.engine.shownTranslation.contains("merhaba dünya") }
        XCTAssertTrue(ok, "çeviri: \(engine.shownTranslation) durum: \(engine.status)")
        XCTAssertTrue(StubURLProtocol.requests.contains { $0.0.url?.host == "generativelanguage.googleapis.com" })
    }

    // MARK: Stres

    func testStartStopStress() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        let before = memoryFootprintMB()
        for i in 0..<40 {
            engine.start()
            if i % 4 == 0 { c.send(frame("Cycle number \(i)")) }
            spin(Double(i % 5) * 0.03)
            engine.stop()
            XCTAssertFalse(engine.running)
        }
        // Hızlı dokunma koruması: toggle çok hızlıysa sıçramamalı
        engine.toggle(.screen)
        engine.toggle(.screen)
        engine.toggle(.screen)
        XCTAssertTrue(engine.running, "0,8 sn içindeki tekrar dokunuşlar yok sayılmalı")
        engine.stop()
        spin(0.5)
        assertMemoryGrowth(memoryFootprintMB() - before, below: 80, "40 kez başlat/durdur")
    }

    func testFrameFloodKeepsMemoryAndStaysResponsive() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        var g = SeededRandom(seed: 21)
        let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]
        // Önceden birkaç farklı kare hazırla
        let frames: [Data] = (0..<8).map { i in
            let cap = (0..<5).map { _ in words[g.int(0..<words.count)] }.joined(separator: " ")
            return Wire.frame(width: pw, height: ph, orientation: 1,
                              pixels: FakeScreen.gray(width: pw, height: ph, texts: [(cap, 0.29)], noiseSeed: i))
        }
        func flood(_ seconds: TimeInterval) -> Int {
            let start = Date()
            var n = 0
            while Date().timeIntervalSince(start) < seconds {
                c.send(frames[n % frames.count])
                n += 1
                spin(0.02)
            }
            return n
        }
        // Isınma: yazı tanıma modelinin ilk yüklenmesi (bir kerelik, sızıntı değil) ölçüme girmesin.
        _ = flood(3)
        spin(0.5)
        let before = memoryFootprintMB()
        let sent = flood(8)
        spin(0.5)
        XCTAssertGreaterThan(sent, 100)
        // Duraklat / devam hâlâ anında çalışmalı
        engine.togglePause()
        XCTAssertTrue(engine.paused)
        engine.togglePause()
        XCTAssertFalse(engine.paused)
        assertMemoryGrowth(memoryFootprintMB() - before, below: 60, "8 sn kare yağmuru (\(sent) kare)")
        engine.stop()
    }

    func testSettingsChurnWhileRunning() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        c.send(frame(nil)); spin(0.5)
        let targets = ["tr", "de", "en", "fr"]
        for i in 0..<60 {
            switch i % 6 {
            case 0: s.targetLang = targets[i % targets.count]
            case 1: s.displayMode = DisplayMode.allCases[i % 3]
            case 2: s.lines = 1 + i % 8
            case 3: s.translator = i % 12 == 3 ? .google : .appleAI
            case 4: s.contentKind = ContentKind.allCases[i % ContentKind.allCases.count]
            default: c.send(frame("Churn line \(i)"))
            }
            spin(0.05)
        }
        spin(1)
        XCTAssertTrue(engine.running, engine.status)
        engine.stop()
    }

    func testLanguageSwitchWhileRunning() {
        s.inputSource = .screen
        s.recentPairs = ["en-US>tr", "de-DE>tr"]
        spin(0.4)
        guard connectExtension() != nil else { return }
        engine.start()
        let p = engine.switchLanguagePair(forward: true)
        XCTAssertEqual(p?.source, "de-DE")
        spin(0.6)
        XCTAssertTrue(engine.running)
        XCTAssertEqual(s.sourceLang, "de-DE")
        engine.switchLanguagePair(forward: false)
        spin(0.6)
        XCTAssertEqual(s.sourceLang, "en-US")
        engine.stop()
    }

    func testBroadcastDropAndReconnectWhileRunning() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        c.close()
        XCTAssertTrue(waitUntil(10) { !self.engine.audioConnected }, "Kopma algılanmadı: \(diag())")
        XCTAssertTrue(engine.running, "Yayın kopunca çeviri kapanmamalı; yeniden bağlanmayı beklemeli")
        guard let c2 = TCPClient(port: AudioReceiver.port, timeout: 8) else { XCTFail("yeniden bağlanılamadı: \(diag())"); return }
        client = c2
        c2.startHeartbeat()
        XCTAssertTrue(waitUntil(8) { self.engine.audioConnected }, diag())
        let cmds = String(decoding: c2.receive(timeout: 1.5), as: UTF8.self)
        // Görüntü isteği: altyazı yokken seyrek (W), varken sık (V); ses kapalı (m).
        XCTAssertTrue((cmds.contains("V") || cmds.contains("W")) && cmds.contains("m"),
                      "Yeni bağlantıya istekler tekrar gitmeli: \(cmds)")
        engine.stop()
    }

    func testSystemEventsWhileRunning() {
        s.inputSource = .screen
        spin(0.4)
        guard connectExtension() != nil else { return }
        engine.start()
        let nc = NotificationCenter.default
        for _ in 0..<10 {
            nc.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            nc.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.post(name: UIApplication.willEnterForegroundNotification, object: nil)
            nc.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            nc.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
            nc.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
            spin(0.05)
        }
        NetworkMonitor.shared.override = false
        spin(0.2)
        NetworkMonitor.shared.override = true
        XCTAssertTrue(engine.running)
        engine.stop()
    }

    // MARK: v3.4 düzeltmeleri

    /// Döndürme kilidi açıkken YouTube tam ekran: iOS kareyi "dikey" etiketler ama içerik yataydır.
    func testRotationLockedLandscapeEndToEnd() {
        s.inputSource = .screen
        spin(0.4)
        guard let c = connectExtension() else { return }
        engine.start()
        func landscape(_ caption: String?) -> Data {
            var texts: [(String, CGFloat)] = []
            if let cap = caption { texts.append((cap, 0.8)) }
            let upright = FakeScreen.gray(width: ph, height: pw, texts: texts, fontSize: 32)
            return Wire.frame(width: pw, height: ph, orientation: 1, pixels: FakeScreen.rotateCW(upright, width: ph, height: pw))
        }
        sendRepeatedly(c, landscape(nil), times: 2)
        let ok = sendUntil(c, landscape("Nobody leaves this room until the storm is over")) {
            self.engine.shownOriginal.lowercased().contains("storm") && self.engine.shownTranslation.contains("TR(")
        }
        XCTAssertTrue(ok, "Kilitli yatay ekranda altyazı okunup çevrilmeli: \(engine.shownOriginal) | "
                      + "\(engine.shownTranslation) | \(diag())")
    }

    /// Yayın açılmadan Başlat'a basıldı; uzantı geç bağlanıyor (askıdan dönüşte dinleyici yenilenmiş olmalı).
    func testLateExtensionIsAcceptedWhileWaiting() {
        s.inputSource = .screen
        spin(0.4)
        XCTAssertFalse(engine.audioConnected)
        engine.start()
        XCTAssertTrue(engine.running)
        spin(4.5)   // bu sürede dinleyici en az bir kez yenilenir
        XCTAssertTrue(ConnectionLog.shared.entries.contains { $0.contains("dinleyici yenileniyor") })
        guard let c = TCPClient(port: AudioReceiver.port, timeout: 5) else { XCTFail("bağlanılamadı"); return }
        client = c
        c.startHeartbeat()
        XCTAssertTrue(waitUntil(6) { self.engine.audioConnected }, "Geç bağlanan uzantı kabul edilmeli: \(engine.status)")
        engine.stop()
    }

    func testDuckingFollowsSettings() {
        s.inputSource = .screen
        s.speakEnabled = true
        s.duckMode = .always
        spin(0.4)
        guard connectExtension() != nil else { return }
        engine.start()
        spin(0.4)
        let session = AVAudioSession.sharedInstance()
        XCTAssertTrue(session.categoryOptions.contains(.duckOthers), "Hep kısık: YouTube sesi kısılmalı")
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers), "Diğer uygulamaların sesi durmamalı")
        s.duckMode = .never
        spin(0.6)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        s.duckMode = .whileSpeaking
        spin(0.6)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "Okuma yokken kısılmamalı")
        // Hızlı aç/kapa stresi
        for i in 0..<20 { s.duckMode = i % 2 == 0 ? .always : .never; spin(0.3) }
        XCTAssertTrue(engine.running)
        engine.stop()
        spin(0.3)
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers), "Durunca kısma kalkmalı")
        s.speakEnabled = false
    }

    func testHybridDraftIsReplacedByFinalAI() {
        s.inputSource = .screen
        s.translator = .claude
        s.claudeKey = "k"
        s.hybridLive = true
        spin(0.4)
        defer { s.claudeKey = "" }
        StubURLProtocol.setHandler { r, _ in
            if r.url?.host == "translate.googleapis.com" {
                return StubNetwork.googleReply("TASLAK(" + StubNetwork.googleQuery(r) + ")")
            }
            return StubURLProtocol.json(["content": [["type": "text", "text": "KESİN"]]])
        }
        guard let c = connectExtension() else { return }
        engine.start()
        sendRepeatedly(c, frame(nil), times: 2)
        // Önce hızlı (taslak) çeviri, cümle bitince yapay zekâ
        let ok = sendUntil(c, frame("Draft then final sentence")) { self.engine.shownTranslation.contains("KESİN") }
        XCTAssertTrue(ok, "son çeviri: \(engine.shownTranslation) | okunan: \(engine.shownOriginal) | \(diag())")
        let hosts = StubURLProtocol.requests.compactMap { $0.0.url?.host }
        XCTAssertTrue(hosts.contains("translate.googleapis.com"), "Canlı kısım ücretsiz motorla: \(hosts)")
        XCTAssertEqual(hosts.filter { $0 == "api.anthropic.com" }.count, 1, "Yapay zekâya cümle başına tek istek: \(hosts)")
        engine.stop()
    }
}
