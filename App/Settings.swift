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

/// Çevrilecek metin nereden alınacak?
enum InputSource: String, CaseIterable, Identifiable {
    case audio, screen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .audio: return "Konuşmayı dinle (ses)"
        case .screen: return "Ekrandaki altyazıyı oku"
        }
    }
}

/// Kutuda ne gösterilecek?
enum DisplayMode: String, CaseIterable, Identifiable {
    case both, translation, original
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: return "Çeviri + orijinal"
        case .translation: return "Sadece çeviri"
        case .original: return "Sadece orijinal"
        }
    }
}

enum SubtitleColor: String, CaseIterable, Identifiable {
    case white, yellow
    var id: String { rawValue }
    var title: String { self == .white ? "Beyaz" : "Sarı" }
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

    @Published var inputSource: InputSource { didSet { d.set(inputSource.rawValue, forKey: "inputSource") } }
    @Published var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var lines: Int { didSet { d.set(lines, forKey: "lines") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var centered: Bool { didSet { d.set(centered, forKey: "centered") } }
    @Published var textColor: SubtitleColor { didSet { d.set(textColor.rawValue, forKey: "textColor") } }
    @Published var pipButtonsResize: Bool { didSet { d.set(pipButtonsResize, forKey: "pipButtonsResize") } }
    /// Altyazı okuma alanı (ekran yüksekliğinin oranı, 0 = üst, 1 = alt)
    @Published var ocrTop: Double { didSet { d.set(ocrTop, forKey: "ocrTop") } }
    @Published var ocrBottom: Double { didSet { d.set(ocrBottom, forKey: "ocrBottom") } }

    static let linesRange = 1...8

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
        inputSource = InputSource(rawValue: d.string(forKey: "inputSource") ?? "") ?? .audio
        // Versiyon 1'deki "orijinali göster" ayarını yeni gösterim moduna taşı.
        let legacyShowOriginal = d.object(forKey: "showOriginal") as? Bool ?? true
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "")
            ?? (legacyShowOriginal ? .both : .translation)
        let storedLines = d.object(forKey: "lines") as? Int ?? 3
        lines = min(max(storedLines, AppSettings.linesRange.lowerBound), AppSettings.linesRange.upperBound)
        fontSize = d.object(forKey: "fontSize") as? Double ?? 58
        centered = d.object(forKey: "centered") as? Bool ?? false
        textColor = SubtitleColor(rawValue: d.string(forKey: "textColor") ?? "") ?? .white
        pipButtonsResize = d.object(forKey: "pipButtonsResize") as? Bool ?? true
        ocrTop = d.object(forKey: "ocrTop") as? Double ?? 0
        ocrBottom = d.object(forKey: "ocrBottom") as? Double ?? 1
    }

    func changeLines(by delta: Int) {
        lines = min(max(lines + delta, AppSettings.linesRange.lowerBound), AppSettings.linesRange.upperBound)
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
    var input: InputSource
    var displayMode: DisplayMode

    init(_ s: AppSettings) {
        sourceLang = s.sourceLang
        targetLang = s.targetLang
        asr = s.asr
        translator = s.translator
        input = s.inputSource
        displayMode = s.displayMode
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
    /// "Sadece orijinal" modunda hiç çeviri isteği yapılmaz.
    var translationEnabled: Bool { displayMode != .original }
    /// Ses modunda Apple tanıma mı kullanılıyor?
    var usesAppleASR: Bool { input == .audio && asr == .apple }
    var usesCloudASR: Bool { input == .audio && asr != .apple }
    var sourceEnglishName: String { Languages.source(sourceLang)?.english ?? "the original language" }
    var targetEnglishName: String { Languages.target(targetLang)?.english ?? targetLang }
}
