import Foundation
import CoreGraphics
import Combine

enum ASREngine: String, CaseIterable, Identifiable {
    case apple, gemini, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: return "Apple (cihazda, ücretsiz)"
        case .gemini: return "Gemini (bulut)"
        case .openai: return "OpenAI (bulut)"
        }
    }
}

enum TranslatorEngine: String, CaseIterable, Identifiable {
    case google, apple, gemini, openai, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google Çeviri (ücretsiz)"
        case .apple: return "Apple Çeviri (cihazda, ücretsiz)"
        case .gemini: return "Gemini"
        case .openai: return "ChatGPT (OpenAI)"
        case .claude: return "Claude"
        }
    }
    var isLLM: Bool { self == .gemini || self == .openai || self == .claude }
}

enum BoxShape: String, CaseIterable, Identifiable {
    case slim, normal, tall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .slim: return "İnce"
        case .normal: return "Normal"
        case .tall: return "Uzun"
        }
    }
    /// genişlik / yükseklik
    var aspect: CGFloat {
        switch self {
        case .slim: return 3.2
        case .normal: return 2.3
        case .tall: return 1.6
        }
    }
}

/// Tüm ayarlar telefonda (UserDefaults) saklanır; hiçbir yere gönderilmez.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var sourceLang: String { didSet { d.set(sourceLang, forKey: "sourceLang") } }
    @Published var targetLang: String { didSet { d.set(targetLang, forKey: "targetLang") } }
    @Published var asr: ASREngine { didSet { d.set(asr.rawValue, forKey: "asr") } }
    @Published var translator: TranslatorEngine { didSet { d.set(translator.rawValue, forKey: "translator") } }

    @Published var geminiKey: String { didSet { d.set(geminiKey, forKey: "geminiKey") } }
    @Published var openaiKey: String { didSet { d.set(openaiKey, forKey: "openaiKey") } }
    @Published var claudeKey: String { didSet { d.set(claudeKey, forKey: "claudeKey") } }

    @Published var geminiModel: String { didSet { d.set(geminiModel, forKey: "geminiModel") } }
    @Published var openaiModel: String { didSet { d.set(openaiModel, forKey: "openaiModel") } }
    @Published var openaiASRModel: String { didSet { d.set(openaiASRModel, forKey: "openaiASRModel") } }
    @Published var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }

    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var showOriginal: Bool { didSet { d.set(showOriginal, forKey: "showOriginal") } }
    @Published var boxShape: BoxShape { didSet { d.set(boxShape.rawValue, forKey: "boxShape") } }

    static let defaultGeminiModel = "gemini-3.1-flash-lite"
    static let defaultOpenAIModel = "gpt-5.4-nano"
    static let defaultOpenAIASRModel = "gpt-4o-mini-transcribe"
    static let defaultClaudeModel = "claude-haiku-5-5"

    private init() {
        sourceLang = d.string(forKey: "sourceLang") ?? "en-US"
        targetLang = d.string(forKey: "targetLang") ?? "tr"
        asr = ASREngine(rawValue: d.string(forKey: "asr") ?? "") ?? .apple
        translator = TranslatorEngine(rawValue: d.string(forKey: "translator") ?? "") ?? .google
        geminiKey = d.string(forKey: "geminiKey") ?? ""
        openaiKey = d.string(forKey: "openaiKey") ?? ""
        claudeKey = d.string(forKey: "claudeKey") ?? ""
        geminiModel = d.string(forKey: "geminiModel") ?? AppSettings.defaultGeminiModel
        openaiModel = d.string(forKey: "openaiModel") ?? AppSettings.defaultOpenAIModel
        openaiASRModel = d.string(forKey: "openaiASRModel") ?? AppSettings.defaultOpenAIASRModel
        claudeModel = d.string(forKey: "claudeModel") ?? AppSettings.defaultClaudeModel
        fontSize = d.object(forKey: "fontSize") as? Double ?? 58
        showOriginal = d.object(forKey: "showOriginal") as? Bool ?? true
        boxShape = BoxShape(rawValue: d.string(forKey: "boxShape") ?? "") ?? .normal
    }
}

/// Bir çalıştırma boyunca kullanılan ayarların değişmez kopyası (arka plan görevleri için güvenli).
struct EngineConfig {
    var sourceLang: String
    var targetLang: String
    var asr: ASREngine
    var translator: TranslatorEngine
    var geminiKey: String
    var openaiKey: String
    var claudeKey: String
    var geminiModel: String
    var openaiModel: String
    var openaiASRModel: String
    var claudeModel: String

    init(_ s: AppSettings) {
        sourceLang = s.sourceLang
        targetLang = s.targetLang
        asr = s.asr
        translator = s.translator
        geminiKey = s.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        openaiKey = s.openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeKey = s.claudeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        func model(_ v: String, _ def: String) -> String {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? def : t
        }
        geminiModel = model(s.geminiModel, AppSettings.defaultGeminiModel)
        openaiModel = model(s.openaiModel, AppSettings.defaultOpenAIModel)
        openaiASRModel = model(s.openaiASRModel, AppSettings.defaultOpenAIASRModel)
        claudeModel = model(s.claudeModel, AppSettings.defaultClaudeModel)
    }

    var sourceIsAuto: Bool { sourceLang == "auto" }
    var sourceEnglishName: String { Languages.source(sourceLang)?.english ?? "the original language" }
    var targetEnglishName: String { Languages.target(targetLang)?.english ?? targetLang }
}
