import Foundation
import Translation

enum APIError: LocalizedError {
    case http(Int, String)
    case badResponse
    case missingKey(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let msg):
            switch code {
            case 401, 403: return "API anahtarı geçersiz (\(code)). \(msg)"
            case 429: return "Çok fazla istek / kota doldu (429). \(msg)"
            default: return "Sunucu hatası \(code): \(msg)"
            }
        case .badResponse: return "Beklenmeyen yanıt"
        case .missingKey(let name): return "\(name) API anahtarı girilmemiş"
        case .unsupported(let msg): return msg
        }
    }
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        c.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: c)
    }()

    @discardableResult
    static func json(_ url: URL, method: String = "POST", headers: [String: String] = [:],
                     body: Any? = nil, rawBody: Data? = nil, contentType: String? = nil) async throws -> Any {
        var req = URLRequest(url: url)
        req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body = body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let raw = rawBody {
            req.httpBody = raw
            if let ct = contentType { req.setValue(ct, forHTTPHeaderField: "Content-Type") }
        }
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(code) else {
            throw APIError.http(code, errorMessage(obj) ?? String(String(decoding: data.prefix(300), as: UTF8.self)))
        }
        guard let o = obj else { throw APIError.badResponse }
        return o
    }

    private static func errorMessage(_ obj: Any?) -> String? {
        guard let d = obj as? [String: Any] else { return nil }
        if let e = d["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let e = d["error"] as? String { return e }
        if let m = d["message"] as? String { return m }
        return nil
    }
}

/// Seçili motorlarla çeviri ve (bulut modunda) ses tanıma yapan servis.
final class TranslationService {
    let cfg: EngineConfig
    private let appleBox: AnyObject?

    init(config: EngineConfig) {
        cfg = config
        if #available(iOS 26.0, *) {
            appleBox = AppleTranslator()
        } else {
            appleBox = nil
        }
    }

    // MARK: Metin çevirisi

    func translate(_ text: String, context: [String]) async throws -> String {
        let out: String
        switch cfg.translator {
        case .google:
            do {
                out = try await google(text)
            } catch {
                // Google geçici olarak engellerse cihaz içi Apple çevirisine düş.
                if let a = try? await apple(text) { out = a } else { throw error }
            }
        case .apple: out = try await apple(text)
        case .gemini: out = try await geminiText(text, context: context)
        case .openai: out = try await openAIChat(text, context: context)
        case .claude: out = try await claude(text, context: context)
        }
        return Self.clean(out)
    }

    static func clean(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("«", "»"), ("'", "'")]
        for (a, b) in quotes where t.count >= 2 && t.first == a && t.last == b {
            t = String(t.dropFirst().dropLast())
        }
        return t
    }

    private var systemPrompt: String {
        let src = cfg.sourceIsAuto ? "whatever language it is in" : cfg.sourceEnglishName
        let tgt = cfg.targetEnglishName
        return """
        You are a professional live subtitle translator. Translate the given speech transcript from \(src) into \(tgt).
        The text is an automatic transcript of a video, livestream or song playing on a phone: it may be an unfinished sentence, \
        lack punctuation or contain recognition mistakes — infer the intended meaning.
        Write natural, fluent, conversational \(tgt) exactly as a skilled subtitler would: keep the speaker's tone, slang and \
        emotion, keep names, be concise.
        Output ONLY the translation of the requested text. No quotes, no notes, no explanations, never translate the context lines.
        """
    }

    private func userPrompt(_ text: String, context: [String]) -> String {
        var s = ""
        if !context.isEmpty {
            s += "Previous lines (context only, do NOT translate):\n" + context.joined(separator: "\n") + "\n\n"
        }
        s += "Translate:\n" + text
        return s
    }

    // MARK: Google (ücretsiz, anahtarsız)

    private static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private func google(_ text: String) async throws -> String {
        let sl = Languages.googleSource(cfg.sourceLang)
        let tl = cfg.targetLang
        guard let q = text.addingPercentEncoding(withAllowedCharacters: Self.unreserved),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&sl=\(sl)&tl=\(tl)&q=\(q)")
        else { throw APIError.badResponse }
        let obj = try await HTTP.json(url, method: "GET")
        guard let root = obj as? [Any], let parts = root.first as? [Any] else { throw APIError.badResponse }
        var out = ""
        for p in parts {
            if let arr = p as? [Any], let s = arr.first as? String { out += s }
        }
        return out
    }

    // MARK: Apple (cihaz içi)

    private func apple(_ text: String) async throws -> String {
        guard #available(iOS 26.0, *) else {
            throw APIError.unsupported("Apple Çeviri için iOS 26 veya üstü gerekli")
        }
        guard let a = appleBox as? AppleTranslator else { throw APIError.badResponse }
        guard !cfg.sourceIsAuto else {
            throw APIError.unsupported("Apple Çeviri için videonun dilini seçmelisin")
        }
        return try await a.translate(text,
                                     source: Languages.appleLanguageID(cfg.sourceLang),
                                     target: Languages.appleLanguageID(cfg.targetLang))
    }

    // MARK: Gemini

    private func geminiThinking(_ model: String) -> [String: Any]? {
        let m = model.lowercased()
        if m.contains("gemini-3") { return ["thinkingLevel": "minimal"] }
        if m.contains("2.5-flash") { return ["thinkingBudget": 0] }
        return nil
    }

    private func gemini(parts: [[String: Any]], system: String, json: Bool) async throws -> String {
        guard !cfg.geminiKey.isEmpty else { throw APIError.missingKey("Gemini") }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(cfg.geminiModel):generateContent")
        else { throw APIError.badResponse }
        var gen: [String: Any] = [:]
        if json { gen["responseMimeType"] = "application/json" }
        if let t = geminiThinking(cfg.geminiModel) { gen["thinkingConfig"] = t }
        func body(_ g: [String: Any]) -> [String: Any] {
            [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": g,
            ]
        }
        let headers = ["x-goog-api-key": cfg.geminiKey]
        let obj: Any
        do {
            obj = try await HTTP.json(url, headers: headers, body: body(gen))
        } catch APIError.http(400, _) where gen["thinkingConfig"] != nil {
            gen.removeValue(forKey: "thinkingConfig")
            obj = try await HTTP.json(url, headers: headers, body: body(gen))
        }
        let cands = (obj as? [String: Any])?["candidates"] as? [[String: Any]]
        let content = cands?.first?["content"] as? [String: Any]
        let ps = content?["parts"] as? [[String: Any]] ?? []
        return ps.filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private func geminiText(_ text: String, context: [String]) async throws -> String {
        try await gemini(parts: [["text": userPrompt(text, context: context)]], system: systemPrompt, json: false)
    }

    // MARK: OpenAI

    private func openAIChat(_ text: String, context: [String]) async throws -> String {
        guard !cfg.openaiKey.isEmpty else { throw APIError.missingKey("OpenAI") }
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        let model = cfg.openaiModel
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt(text, context: context)],
            ],
        ]
        let m = model.lowercased()
        if m.hasPrefix("gpt-5.") { body["reasoning_effort"] = "none" }
        else if m.hasPrefix("gpt-5") { body["reasoning_effort"] = "minimal" }
        else if m.hasPrefix("o") { body["reasoning_effort"] = "low" }
        let headers = ["Authorization": "Bearer \(cfg.openaiKey)"]
        let obj: Any
        do {
            obj = try await HTTP.json(url, headers: headers, body: body)
        } catch APIError.http(400, _) where body["reasoning_effort"] != nil {
            body.removeValue(forKey: "reasoning_effort")
            obj = try await HTTP.json(url, headers: headers, body: body)
        }
        let choices = (obj as? [String: Any])?["choices"] as? [[String: Any]]
        let msg = choices?.first?["message"] as? [String: Any]
        return msg?["content"] as? String ?? ""
    }

    private func openAITranscribe(_ wav: Data, prompt: String) async throws -> String {
        guard !cfg.openaiKey.isEmpty else { throw APIError.missingKey("OpenAI") }
        let url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", cfg.openaiASRModel)
        field("response_format", "json")
        if let lang = Languages.isoCode(cfg.sourceLang) { field("language", lang) }
        if !prompt.isEmpty { field("prompt", String(prompt.suffix(400))) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let obj = try await HTTP.json(url, headers: ["Authorization": "Bearer \(cfg.openaiKey)"],
                                      rawBody: body, contentType: "multipart/form-data; boundary=\(boundary)")
        return (obj as? [String: Any])?["text"] as? String ?? ""
    }

    // MARK: Claude

    private func claude(_ text: String, context: [String]) async throws -> String {
        guard !cfg.claudeKey.isEmpty else { throw APIError.missingKey("Claude") }
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let body: [String: Any] = [
            "model": cfg.claudeModel,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userPrompt(text, context: context)]],
        ]
        let obj = try await HTTP.json(url, headers: [
            "x-api-key": cfg.claudeKey,
            "anthropic-version": "2023-06-01",
        ], body: body)
        let blocks = (obj as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    // MARK: Bulut ses tanıma (+ çeviri)

    /// Bir ses parçasını yazıya döker ve çevirir. (orijinal, çeviri) döner; konuşma yoksa boş metinler.
    func transcribeAndTranslate(_ samples: [Int16], context: [String]) async throws -> (String, String) {
        let wav = Chunker.wav(samples)
        var original = ""
        switch cfg.asr {
        case .gemini:
            let both = cfg.translationEnabled && cfg.translator == .gemini
            let (o, t) = try await geminiAudio(wav, context: context, translate: both)
            if both { return (o, Self.clean(t)) }
            original = o
        case .openai:
            original = try await openAITranscribe(wav, prompt: context.joined(separator: " "))
        case .apple:
            throw APIError.unsupported("Geçersiz mod")
        }
        original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isHallucination(original) { return ("", "") }
        guard !original.isEmpty else { return ("", "") }
        guard cfg.translationEnabled else { return (original, "") }
        let t = try await translate(original, context: context)
        return (original, t)
    }

    private func geminiAudio(_ wav: Data, context: [String], translate: Bool) async throws -> (String, String) {
        let tgt = cfg.targetEnglishName
        let lang = cfg.sourceIsAuto ? "" : " The audio is most likely in \(cfg.sourceEnglishName)."
        var prompt = "This is a short clip of audio playing on a phone (a video, stream or song).\(lang)\n"
        if !context.isEmpty {
            prompt += "Transcript of the preceding audio, for context only: «\(context.joined(separator: " "))»\n"
        }
        if translate {
            prompt += """
            1) Transcribe exactly what is spoken or sung in this clip, in its original language.
            2) Translate that transcript into natural, fluent \(tgt) like a professional subtitler.
            If there is no intelligible speech or singing (only music/noise/silence), use empty strings. Never invent words.
            Reply ONLY with JSON: {"original": "...", "translation": "..."}
            """
        } else {
            prompt += """
            Transcribe exactly what is spoken or sung in this clip, in its original language.
            If there is no intelligible speech or singing, use an empty string. Never invent words.
            Reply ONLY with JSON: {"original": "..."}
            """
        }
        let parts: [[String: Any]] = [
            ["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]],
            ["text": prompt],
        ]
        let raw = try await gemini(parts: parts, system: "You are an accurate speech transcriber and subtitle translator.", json: true)
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ((obj["original"] as? String) ?? "", (obj["translation"] as? String) ?? "")
        }
        return translate ? ("", s) : (s, "")
    }

    /// Sessizlikte bazı modellerin uydurduğu kalıp cümleler.
    static func isHallucination(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if t.isEmpty { return true }
        let exact: Set<String> = ["you", "bye", "music", "thank you", "thanks", "[music]", "♪"]
        if exact.contains(t) { return true }
        let prefixes = ["thank you for watching", "thanks for watching", "altyazı m.k", "abone olmayı unutmayın",
                        "subtitles by", "please subscribe", "transcribed by"]
        return prefixes.contains { t.hasPrefix($0) }
    }
}

/// Apple Translation oturumu (iOS 26+). Çağrılar sırayla işlenir.
@available(iOS 26.0, *)
final class AppleTranslator {
    private var session: TranslationSession?
    private var key = ""
    private var tail: Task<Void, Never>?
    private let lock = NSLock()

    func translate(_ text: String, source: String, target: String) async throws -> String {
        lock.lock()
        let previous = tail
        let job = Task<String, Error> {
            _ = await previous?.value
            return try await self.run(text, source: source, target: target)
        }
        tail = Task { _ = try? await job.value }
        lock.unlock()
        return try await job.value
    }

    private func run(_ text: String, source: String, target: String) async throws -> String {
        let k = source + ">" + target
        if session == nil || key != k {
            session = TranslationSession(installedSource: Locale.Language(identifier: source),
                                         target: Locale.Language(identifier: target))
            key = k
        }
        guard let s = session else { throw APIError.badResponse }
        do {
            return try await s.translate(text).targetText
        } catch {
            throw APIError.unsupported("Apple Çeviri: dil paketi indirilmemiş olabilir (uygulamadaki “Dil paketini indir”).")
        }
    }
}
