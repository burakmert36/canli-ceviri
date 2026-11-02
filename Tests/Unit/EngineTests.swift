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
                        "portraitArea", "landscapeArea", "recentPairs", "hybridLive", "lines", "contentKind", "claudeKey"]

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
        XCTAssertTrue(waitUntil(5) { self.engine.audioConnected }, "Bağlantı algılanmadı", file: file, line: line)
        return c
    }

    private let pw = 600, ph = 1300

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
        sendRepeatedly(c, frame("Hello my good friend"))
        sendRepeatedly(c, frame("my good friend how are you today"))
        let ok = waitUntil(20) {
            self.engine.shownOriginal.lowercased().contains("today") && self.engine.shownTranslation.contains("TR(")
        }
        XCTAssertTrue(ok, "orijinal: \(engine.shownOriginal) | çeviri: \(engine.shownTranslation) | durum: \(engine.status)")
        XCTAssertFalse(engine.shownOriginal.lowercased().contains("title"), "Başlık alan dışında kalmalı")
        // Kayan altyazı tekrar etmemeli
        let o = engine.shownOriginal.lowercased()
        XCTAssertEqual(o.components(separatedBy: "friend").count - 1, 1, "Tekrarlanan kelimeler: \(o)")
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
        XCTAssertLessThan(memoryFootprintMB() - before, 80)
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
        let before = memoryFootprintMB()
        let start = Date()
        var sent = 0
        while Date().timeIntervalSince(start) < 8 {
            c.send(frames[sent % frames.count])
            sent += 1
            spin(0.02)
        }
        XCTAssertGreaterThan(sent, 100)
        // Duraklat / devam hâlâ anında çalışmalı
        engine.togglePause()
        XCTAssertTrue(engine.paused)
        engine.togglePause()
        XCTAssertFalse(engine.paused)
        let growth = memoryFootprintMB() - before
        XCTAssertLessThan(growth, 120, "Kare yağmurunda bellek \(growth) MB arttı")
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
        XCTAssertTrue(waitUntil(5) { !self.engine.audioConnected })
        XCTAssertTrue(engine.running, "Yayın kopunca çeviri kapanmamalı; yeniden bağlanmayı beklemeli")
        guard let c2 = TCPClient(port: AudioReceiver.port) else { XCTFail(); return }
        client = c2
        XCTAssertTrue(waitUntil(5) { self.engine.audioConnected })
        let cmds = String(decoding: c2.receive(timeout: 1), as: UTF8.self)
        XCTAssertTrue(cmds.contains("V") && cmds.contains("m"), "Yeni bağlantıya istekler tekrar gitmeli: \(cmds)")
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
        sendRepeatedly(c, frame("Draft then final sentence"))
        // Önce hızlı (taslak) çeviri, cümle bitince yapay zekâ
        XCTAssertTrue(waitUntil(20) { self.engine.shownTranslation.contains("KESİN") },
                      "son çeviri: \(engine.shownTranslation)")
        let hosts = StubURLProtocol.requests.compactMap { $0.0.url?.host }
        XCTAssertTrue(hosts.contains("translate.googleapis.com"), "Canlı kısım ücretsiz motorla: \(hosts)")
        XCTAssertEqual(hosts.filter { $0 == "api.anthropic.com" }.count, 1, "Yapay zekâya cümle başına tek istek: \(hosts)")
        engine.stop()
    }
}
