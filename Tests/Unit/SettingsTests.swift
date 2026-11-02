import XCTest
@testable import CanliCeviri

/// Ayarlar, diller ve hızlı dil değiştirme.
final class SettingsTests: XCTestCase {
    private let s = AppSettings.shared
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        saved = [
            "sourceLang": s.sourceLang, "targetLang": s.targetLang, "recentPairs": s.recentPairs,
            "inputSource": s.inputSource.rawValue, "asr": s.asr.rawValue, "translator": s.translator.rawValue,
            "lines": s.lines, "boxLocked": s.boxLocked, "pipButtons": s.pipButtons.rawValue,
            "portraitArea": s.portraitArea, "displayMode": s.displayMode.rawValue,
        ]
    }

    override func tearDown() {
        s.sourceLang = saved["sourceLang"] as! String
        s.targetLang = saved["targetLang"] as! String
        s.recentPairs = saved["recentPairs"] as! [String]
        s.inputSource = InputSource(rawValue: saved["inputSource"] as! String)!
        s.asr = ASREngine(rawValue: saved["asr"] as! String)!
        s.translator = TranslatorEngine(rawValue: saved["translator"] as! String)!
        s.lines = saved["lines"] as! Int
        s.boxLocked = saved["boxLocked"] as! Bool
        s.pipButtons = PiPButtonAction(rawValue: saved["pipButtons"] as! String)!
        s.portraitArea = saved["portraitArea"] as! CGRect
        s.displayMode = DisplayMode(rawValue: saved["displayMode"] as! String)!
        super.tearDown()
    }

    func testAreasPersistAsNumbers() {
        let r = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        s.portraitArea = r
        let stored = UserDefaults.standard.array(forKey: "portraitArea") as? [Double]
        XCTAssertEqual(stored, [0.1, 0.2, 0.3, 0.4])
    }

    func testLinesClampAndLock() {
        s.boxLocked = false
        s.lines = 8
        s.changeLines(by: 5)
        XCTAssertEqual(s.lines, 8)
        s.lines = 1
        s.changeLines(by: -3)
        XCTAssertEqual(s.lines, 1)
        s.boxLocked = true
        s.changeLines(by: 1)
        XCTAssertEqual(s.lines, 1, "Kilitliyken değişmemeli")
    }

    func testPiPButtonVisibility() {
        s.boxLocked = true
        s.pipButtons = .lines
        XCTAssertFalse(s.pipButtonsVisible)
        s.pipButtons = .language
        XCTAssertTrue(s.pipButtonsVisible, "Dil değiştirme kilitten bağımsız")
        s.pipButtons = .off
        XCTAssertFalse(s.pipButtonsVisible)
    }

    func testRememberPairKeepsUniqueNewestFirstMaxFive() {
        s.recentPairs = []
        let pairs = [("en-US", "tr"), ("de-DE", "tr"), ("en-US", "tr"), ("fr-FR", "tr"), ("ja-JP", "en"),
                     ("es-ES", "tr"), ("ru-RU", "tr")]
        for (a, b) in pairs { s.sourceLang = a; s.targetLang = b; s.rememberCurrentPair() }
        XCTAssertEqual(s.recentPairs.first, "ru-RU>tr")
        XCTAssertEqual(s.recentPairs.count, 5)
        XCTAssertEqual(Set(s.recentPairs).count, 5)
    }

    func testCycleGoesThroughPairsAndWraps() {
        s.recentPairs = ["en-US>tr", "de-DE>tr", "fr-FR>tr"]
        s.inputSource = .screen
        s.translator = .google
        s.sourceLang = "en-US"; s.targetLang = "tr"
        let list = s.quickPairs()
        XCTAssertGreaterThanOrEqual(list.count, 3)
        var seen: [String] = [s.currentPair.key]
        for _ in 0..<list.count {
            XCTAssertNotNil(s.cycleLanguagePair(forward: true))
            seen.append(s.currentPair.key)
        }
        XCTAssertEqual(seen.first, seen.last, "Tam tur sonunda başa dönmeli")
        XCTAssertEqual(Set(seen).count, list.count)
        // Geri yönde
        s.cycleLanguagePair(forward: false)
        XCTAssertEqual(s.currentPair, list.last)
    }

    func testCycleSkipsAutoWhenAppleSpeechInUse() {
        s.recentPairs = ["auto>tr", "en-US>tr"]
        s.translator = .google
        s.inputSource = .audio
        s.asr = .apple
        XCTAssertFalse(s.quickPairs().contains(LangPair(source: "auto", target: "tr")),
                       "Apple ses tanıma 'otomatik' dili desteklemez")
        s.asr = .gemini
        XCTAssertTrue(s.quickPairs().contains(LangPair(source: "auto", target: "tr")))
    }

    func testCorruptStoredPairsAreIgnored() {
        XCTAssertNil(LangPair(key: "garbage"))
        XCTAssertNil(LangPair(key: "xx-XX>tr"))
        XCTAssertNil(LangPair(key: "en-US>zz"))
        XCTAssertNil(LangPair(key: ">"))
        XCTAssertNil(LangPair(key: "en-US>tr>de"))
        XCTAssertNotNil(LangPair(key: "en-US>tr"))
        XCTAssertEqual(LangPair(key: "en-US>tr")?.title, "İngilizce → Türkçe")
    }

    func testLanguageTablesAreConsistent() {
        XCTAssertEqual(Set(Languages.sources.map(\.id)).count, Languages.sources.count, "Yinelenen kaynak dil")
        XCTAssertEqual(Set(Languages.targets.map(\.id)).count, Languages.targets.count, "Yinelenen hedef dil")
        for src in Languages.sources {
            XCTAssertFalse(Languages.googleSource(src.id).isEmpty)
            XCTAssertNotNil(Languages.isoCode(src.id))
            XCTAssertFalse(Languages.appleLanguageID(src.id).isEmpty)
            for tgt in Languages.targets {
                if let sw = Languages.swapped(source: src.id, target: tgt.id) {
                    XCTAssertNotNil(Languages.source(sw.source), "\(src.id)→\(tgt.id)")
                    XCTAssertNotNil(Languages.target(sw.target), "\(src.id)→\(tgt.id)")
                }
            }
        }
        XCTAssertNil(Languages.swapped(source: "auto", target: "tr"))
        XCTAssertEqual(Languages.swapped(source: "en-US", target: "tr")?.source, "tr-TR")
        XCTAssertEqual(Languages.swapped(source: "en-US", target: "tr")?.target, "en")
    }

    func testEngineConfigFallsBackToDefaultModels() {
        let old = (s.geminiModel, s.openaiModel, s.claudeModel)
        defer { s.geminiModel = old.0; s.openaiModel = old.1; s.claudeModel = old.2 }
        s.geminiModel = "   "
        s.openaiModel = ""
        s.claudeModel = "\n"
        let c = EngineConfig(s)
        XCTAssertEqual(c.geminiModel, AppSettings.defaultGeminiModel)
        XCTAssertEqual(c.openaiModel, AppSettings.defaultOpenAIModel)
        XCTAssertEqual(c.claudeModel, AppSettings.defaultClaudeModel)
    }

    func testHybridOnlyForAIEngines() {
        var c = EngineConfig(s)
        c.hybrid = true
        for e in TranslatorEngine.allCases {
            c.translator = e
            XCTAssertEqual(c.hybridActive, e.isLLM, "\(e)")
        }
        c.hybrid = false
        c.translator = .claude
        XCTAssertFalse(c.hybridActive)
    }

    func testPresetsProduceValidConfigs() {
        for p in AppSettings.Preset.allCases {
            s.apply(p)
            let c = EngineConfig(s)
            if c.usesAppleASR { XCTAssertFalse(c.sourceIsAuto, "\(p): Apple ses tanıma otomatik dil desteklemez") }
        }
    }
}
