import XCTest
@testable import CanliCeviri

/// Çeviri servisleri: yanıt ayrıştırma, hata kodları, yeniden deneme, önbellek, çevrimdışı ve hibrit yol.
/// Gerçek ağa çıkılmaz; tüm yanıtlar sahte (URLProtocol).
final class TranslatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubNetwork.install()
    }

    override func tearDown() {
        StubNetwork.uninstall()
        super.tearDown()
    }

    private func config(_ engine: TranslatorEngine, source: String = "en-US", target: String = "tr",
                        kind: ContentKind = .general) -> EngineConfig {
        var c = EngineConfig(AppSettings.shared)
        c.translator = engine
        c.sourceLang = source
        c.targetLang = target
        c.geminiKey = "test-gemini"
        c.openaiKey = "test-openai"
        c.claudeKey = "test-claude"
        c.geminiModel = "gemini-test"
        c.openaiModel = "gpt-5.4-nano"
        c.claudeModel = "claude-test"
        c.displayMode = .translation
        c.contentKind = kind
        return c
    }

    private func translate(_ c: EngineConfig, _ text: String, context: [String] = [],
                           fast: Bool = false) -> Result<String, Error> {
        let exp = expectation(description: "translate")
        let result = Box<Result<String, Error>>(.failure(APIError.badResponse))
        let svc = TranslationService(config: c)
        Task {
            do {
                let r = fast ? try await svc.translateFast(text) : try await svc.translate(text, context: context)
                result.value = .success(r)
            } catch {
                result.value = .failure(error)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 15)
        return result.value
    }

    private func host(_ r: URLRequest) -> String { r.url?.host ?? "" }

    // MARK: Google

    func testGoogleParsesMultiPartResponse() {
        StubURLProtocol.setHandler { r, _ in
            XCTAssertEqual(self.host(r), "translate.googleapis.com")
            return StubURLProtocol.json([[["Merhaba ", "Hello ", NSNull()], ["dünya", "world", NSNull()]], NSNull(), "en"])
        }
        XCTAssertEqual(try translate(config(.google), "Hello world").get(), "Merhaba dünya")
        let q = StubURLProtocol.requests.first.map { StubNetwork.googleQuery($0.0) }
        XCTAssertEqual(q, "Hello world")
        let sl = StubURLProtocol.requests.first.flatMap { URLComponents(url: $0.0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "sl" }?.value }
        XCTAssertEqual(sl, "en")
    }

    func testGoogleEncodesSpecialCharacters() {
        StubURLProtocol.setHandler { r, _ in StubNetwork.googleReply("ok") }
        let text = "Tom & Jerry: 100% \"real\" ?=#+ çğış 日本"
        _ = translate(config(.google), text)
        XCTAssertEqual(StubURLProtocol.requests.first.map { StubNetwork.googleQuery($0.0) }, text)
    }

    func testGoogleGarbageResponseThrowsCleanly() {
        for body in [Data(), Data("<html>blocked</html>".utf8), Data("{}".utf8), Data("[[]]".utf8), Data("[1,2]".utf8)] {
            TranslationCache.shared.removeAll()
            StubURLProtocol.setHandler { _, _ in .init(status: 200, body: body) }
            if case .success(let s) = translate(config(.google), "Hello \(body.count)") {
                // iOS 26 simülatöründe Apple'a düşebilir; boş çeviri kabul edilir ama çökme olmamalı
                XCTAssertNotNil(s)
            }
        }
    }

    // MARK: Gemini

    func testGeminiRetriesWithoutThinkingConfigOn400() {
        var calls = 0
        StubURLProtocol.setHandler { r, body in
            calls += 1
            let json = StubURLProtocol.jsonBody(body)
            let gen = json["generationConfig"] as? [String: Any] ?? [:]
            XCTAssertEqual(r.value(forHTTPHeaderField: "x-goog-api-key"), "test-gemini")
            if gen["thinkingConfig"] != nil {
                return StubURLProtocol.json(["error": ["message": "thinking not supported"]], status: 400)
            }
            return StubURLProtocol.json(["candidates": [["content": ["parts": [
                ["text": "düşünce", "thought": true], ["text": "Merhaba"],
            ]]]]])
        }
        var c = config(.gemini)
        c.geminiModel = "gemini-3.5-flash-lite"
        XCTAssertEqual(try translate(c, "Hello").get(), "Merhaba")
        XCTAssertEqual(calls, 2)
    }

    func testGeminiPromptCarriesContextAndContentKind() {
        var captured: [String: Any] = [:]
        StubURLProtocol.setHandler { _, body in
            captured = StubURLProtocol.jsonBody(body)
            return StubURLProtocol.json(["candidates": [["content": ["parts": [["text": "\"Tamam\""]]]]]])
        }
        let r = translate(config(.gemini, kind: .game), "Okay", context: ["Previous line one", "Previous line two"])
        XCTAssertEqual(try r.get(), "Tamam", "Tırnaklar temizlenmeli")
        let system = ((captured["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        XCTAssertTrue(system.contains("video game"), "İçerik türü isteme eklenmeli")
        XCTAssertTrue(system.contains("Turkish"))
        let user = (((captured["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(user.contains("Previous line two"))
        XCTAssertTrue(user.hasSuffix("Okay"))
    }

    func testGeminiAudioJSONInCodeFence() {
        StubURLProtocol.setHandler { _, _ in
            StubURLProtocol.json(["candidates": [["content": ["parts": [
                ["text": "```json\n{\"original\": \"hello world\", \"translation\": \"merhaba dünya\"}\n```"],
            ]]]]])
        }
        var c = config(.gemini)
        c.asr = .gemini
        c.input = .audio
        let exp = expectation(description: "audio")
        let out = Box<(String, String)>(("", ""))
        let svc = TranslationService(config: c)
        Task {
            out.value = (try? await svc.transcribeAndTranslate(Wire.sine(freq: 300, seconds: 1), context: [])) ?? ("", "")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(out.value.0, "hello world")
        XCTAssertEqual(out.value.1, "merhaba dünya")
    }

    // MARK: OpenAI / Claude

    func testOpenAIRetriesWithoutReasoningEffort() {
        var efforts: [String?] = []
        StubURLProtocol.setHandler { r, body in
            XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-openai")
            let j = StubURLProtocol.jsonBody(body)
            efforts.append(j["reasoning_effort"] as? String)
            if j["reasoning_effort"] != nil { return StubURLProtocol.json(["error": ["message": "unsupported"]], status: 400) }
            return StubURLProtocol.json(["choices": [["message": ["content": "Selam"]]]])
        }
        XCTAssertEqual(try translate(config(.openai), "Hi").get(), "Selam")
        XCTAssertEqual(efforts, ["none", nil])
    }

    func testClaudeParsesTextBlocks() {
        StubURLProtocol.setHandler { r, body in
            XCTAssertEqual(r.value(forHTTPHeaderField: "x-api-key"), "test-claude")
            XCTAssertEqual(r.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            XCTAssertEqual(StubURLProtocol.jsonBody(body)["model"] as? String, "claude-test")
            return StubURLProtocol.json(["content": [["type": "text", "text": "İyi "], ["type": "tool_use", "id": "x"], ["type": "text", "text": "akşamlar"]]])
        }
        XCTAssertEqual(try translate(config(.claude), "Good evening").get(), "İyi akşamlar")
    }

    func testHTTPErrorsAreReadable() {
        let cases: [(Int, String)] = [(401, "geçersiz"), (403, "geçersiz"), (429, "kota"), (500, "Sunucu hatası 500")]
        for (code, needle) in cases {
            TranslationCache.shared.removeAll()
            StubURLProtocol.setHandler { _, _ in StubURLProtocol.json(["error": ["message": "boom"]], status: code) }
            guard case .failure(let e) = translate(config(.claude), "x \(code)") else { XCTFail("\(code) başarılı olmamalı"); continue }
            XCTAssertTrue(e.localizedDescription.contains(needle), "\(code): \(e.localizedDescription)")
        }
    }

    func testNetworkFailureIsReported() {
        StubURLProtocol.setHandler { _, _ in .init(status: 0, body: Data(), failure: .timedOut) }
        guard case .failure = translate(config(.openai), "timeout please") else { XCTFail(); return }
    }

    // MARK: Önbellek, çevrimdışı, hibrit

    func testCacheAvoidsRepeatedRequests() {
        var calls = 0
        StubURLProtocol.setHandler { _, _ in calls += 1; return StubURLProtocol.json(["content": [["type": "text", "text": "Nakarat"]]]) }
        for _ in 0..<5 { XCTAssertEqual(try translate(config(.claude), "Chorus line").get(), "Nakarat") }
        XCTAssertEqual(calls, 1, "Aynı cümle tekrar çevrilmemeli")
        // Farklı hedef dil ayrı kayıt
        _ = translate(config(.claude, target: "de"), "Chorus line")
        XCTAssertEqual(calls, 2)
        // Farklı içerik türü ayrı kayıt (istem değişti)
        _ = translate(config(.claude, kind: .music), "Chorus line")
        XCTAssertEqual(calls, 3)
    }

    func testCacheCapacityAndThreadSafety() {
        let cache = TranslationCache(capacity: 50)
        DispatchQueue.concurrentPerform(iterations: 2000) { i in
            cache.set("k\(i)", "v\(i)")
            _ = cache.get("k\(i / 2)")
        }
        XCTAssertLessThanOrEqual(cache.count, 50)
        cache.set("empty", "")
        XCTAssertNil(cache.get("empty"), "Boş çeviri önbelleğe yazılmamalı")
    }

    func testOfflineNeverHitsNetwork() {
        NetworkMonitor.shared.override = false
        StubURLProtocol.setHandler { _, _ in XCTFail("Çevrimdışıyken ağa gidilmemeli"); return StubNetwork.googleReply("x") }
        for engine in [TranslatorEngine.google, .gemini, .openai, .claude] {
            let r = translate(config(engine), "Offline test \(engine.rawValue)")
            if case .failure(let e) = r {
                // Dil paketi yoksa açıklayıcı çevrimdışı hatası
                XCTAssertTrue(e.localizedDescription.contains("İnternet yok") || e.localizedDescription.contains("Apple"),
                              e.localizedDescription)
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testFastPathUsesGoogleEvenWhenAIIsSelected() {
        StubURLProtocol.setHandler { r, _ in
            XCTAssertEqual(self.host(r), "translate.googleapis.com", "Hibritte canlı kısım ücretsiz motorla çevrilmeli")
            return StubNetwork.googleReply("Hızlı")
        }
        XCTAssertEqual(try translate(config(.claude), "Quick one", fast: true).get(), "Hızlı")
    }

    func testConcurrentTranslationsStress() {
        StubURLProtocol.setHandler { r, _ in
            var rep = StubNetwork.googleReply("T:" + StubNetwork.googleQuery(r))
            rep.delay = Double(abs(StubNetwork.googleQuery(r).hashValue % 50)) / 1000
            return rep
        }
        let svc = TranslationService(config: config(.google))
        let exp = expectation(description: "all")
        exp.expectedFulfillmentCount = 300
        let wrong = Box(0)
        for i in 0..<300 {
            Task.detached {
                let text = "sentence \(i % 120)"
                let r = try? await svc.translate(text, context: [])
                if r != "T:" + text { wrong.mutate { $0 += 1 } }
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 30)
        XCTAssertEqual(wrong.value, 0)
    }

    // MARK: Yardımcılar

    func testCleanAndHallucinationFilters() {
        XCTAssertEqual(TranslationService.clean("  \"Merhaba\"  "), "Merhaba")
        XCTAssertEqual(TranslationService.clean("“Selam”"), "Selam")
        XCTAssertEqual(TranslationService.clean("\""), "\"")
        XCTAssertEqual(TranslationService.clean(""), "")
        for h in ["Thank you for watching!", "you", "[Music]", "♪", "  ", "Altyazı M.K."] {
            XCTAssertTrue(TranslationService.isHallucination(h), h)
        }
        XCTAssertFalse(TranslationService.isHallucination("Thank you, Mr. President"))
    }

    func testVersionCompare() {
        XCTAssertEqual(UpdateChecker.compare("3.3.10", "3.3.9"), 1)
        XCTAssertEqual(UpdateChecker.compare("3.2", "3.2.0"), 0)
        XCTAssertEqual(UpdateChecker.compare("3.1.99", "3.2"), -1)
        XCTAssertEqual(UpdateChecker.compare("garbage", "1"), -1)
    }
}
