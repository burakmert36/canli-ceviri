import Foundation
import CoreGraphics
import Combine
import SwiftUI
import UIKit

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
    /// Kamera modundaki karşılığı
    var cameraTitle: String {
        switch self {
        case .audio: return "Konuşmayı dinle"
        case .screen: return "Altyazıyı oku"
        }
    }
}

/// Uygulamanın çalışma biçimi: telefonun kendi ekranı (yayın + kutu) ya da kamera/mikrofon (TV).
enum RunMode {
    case screen, camera
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
    case white, yellow, cyan, green
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return "Beyaz"
        case .yellow: return "Sarı"
        case .cyan: return "Turkuaz"
        case .green: return "Yeşil"
        }
    }
    var uiColor: UIColor {
        switch self {
        case .white: return .white
        case .yellow: return UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 1)
        case .cyan: return UIColor(red: 0.45, green: 0.9, blue: 1, alpha: 1)
        case .green: return UIColor(red: 0.5, green: 0.95, blue: 0.55, alpha: 1)
        }
    }
}

enum BoxBackground: String, CaseIterable, Identifiable {
    case black, graphite, navy, wine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .black: return "Siyah"
        case .graphite: return "Grafit"
        case .navy: return "Lacivert"
        case .wine: return "Bordo"
        }
    }
    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .graphite: return UIColor(white: 0.13, alpha: 1)
        case .navy: return UIColor(red: 0.05, green: 0.08, blue: 0.2, alpha: 1)
        case .wine: return UIColor(red: 0.2, green: 0.04, blue: 0.08, alpha: 1)
        }
    }
}

enum FontStyleChoice: String, CaseIterable, Identifiable {
    case standard, rounded, mono, serif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "Standart"
        case .rounded: return "Yuvarlak"
        case .mono: return "Daktilo"
        case .serif: return "Klasik"
        }
    }
    var design: UIFontDescriptor.SystemDesign {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        case .serif: return .serif
        }
    }
    var swiftUIDesign: Font.Design {
        switch self {
        case .standard: return .default
        case .rounded: return .rounded
        case .mono: return .monospaced
        case .serif: return .serif
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Sistem"
        case .dark: return "Koyu"
        case .light: return "Açık"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, purple, pink, orange, green, teal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blue: return "Mavi"
        case .purple: return "Mor"
        case .pink: return "Pembe"
        case .orange: return "Turuncu"
        case .green: return "Yeşil"
        case .teal: return "Turkuaz"
        }
    }
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        }
    }
}

enum SpeakTarget: String, CaseIterable, Identifiable {
    case translation, original
    var id: String { rawValue }
    var title: String { self == .translation ? "Çeviriyi oku" : "Orijinali oku" }
}

/// Tüm ayarlar telefonda (UserDefaults) saklanır; hiçbir yere gönderilmez.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Diller ve motorlar
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

    // Ekran modu
    @Published var inputSource: InputSource { didSet { d.set(inputSource.rawValue, forKey: "inputSource") } }
    /// Altyazı okuma alanı (ekran yüksekliğinin oranı, 0 = üst, 1 = alt)
    @Published var ocrTop: Double { didSet { d.set(ocrTop, forKey: "ocrTop") } }
    @Published var ocrBottom: Double { didSet { d.set(ocrBottom, forKey: "ocrBottom") } }
    @Published var pipButtonsResize: Bool { didSet { d.set(pipButtonsResize, forKey: "pipButtonsResize") } }
    /// Altyazının yerini otomatik bul (video oynayan bölge). Kapalıysa üst/alt sınır elle seçilir.
    @Published var ocrAuto: Bool { didSet { d.set(ocrAuto, forKey: "ocrAuto") } }
    /// Kutu boyutu ayarlarını kilitler (⏪ ⏩ ve boyut ayarları kapanır).
    @Published var boxLocked: Bool { didSet { d.set(boxLocked, forKey: "boxLocked") } }

    // Kamera / TV modu
    @Published var camInput: InputSource { didSet { d.set(camInput.rawValue, forKey: "camInput") } }
    @Published var camX: Double { didSet { d.set(camX, forKey: "camX") } }
    @Published var camY: Double { didSet { d.set(camY, forKey: "camY") } }
    @Published var camW: Double { didSet { d.set(camW, forKey: "camW") } }
    @Published var camH: Double { didSet { d.set(camH, forKey: "camH") } }
    @Published var camZoom: Double { didSet { d.set(camZoom, forKey: "camZoom") } }

    // Altyazı kutusu görünümü
    @Published var displayMode: DisplayMode { didSet { d.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var lines: Int { didSet { d.set(lines, forKey: "lines") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var centered: Bool { didSet { d.set(centered, forKey: "centered") } }
    @Published var textColor: SubtitleColor { didSet { d.set(textColor.rawValue, forKey: "textColor") } }
    @Published var boxBackground: BoxBackground { didSet { d.set(boxBackground.rawValue, forKey: "boxBackground") } }
    @Published var fontStyle: FontStyleChoice { didSet { d.set(fontStyle.rawValue, forKey: "fontStyle") } }
    @Published var boldText: Bool { didSet { d.set(boldText, forKey: "boldText") } }

    // Uygulama görünümü
    @Published var appTheme: AppTheme { didSet { d.set(appTheme.rawValue, forKey: "appTheme") } }
    @Published var accent: AccentChoice { didSet { d.set(accent.rawValue, forKey: "accent") } }

    // Seslendirme
    @Published var speakEnabled: Bool { didSet { d.set(speakEnabled, forKey: "speakEnabled") } }
    @Published var speakTarget: SpeakTarget { didSet { d.set(speakTarget.rawValue, forKey: "speakTarget") } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: "voiceID") } }
    @Published var speechRate: Double { didSet { d.set(speechRate, forKey: "speechRate") } }

    // Diğer
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

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
        ocrTop = d.object(forKey: "ocrTop") as? Double ?? 0
        ocrBottom = d.object(forKey: "ocrBottom") as? Double ?? 1
        pipButtonsResize = d.object(forKey: "pipButtonsResize") as? Bool ?? true
        ocrAuto = d.object(forKey: "ocrAuto") as? Bool ?? true
        boxLocked = d.object(forKey: "boxLocked") as? Bool ?? false

        camInput = InputSource(rawValue: d.string(forKey: "camInput") ?? "") ?? .screen
        camX = d.object(forKey: "camX") as? Double ?? 0.05
        camY = d.object(forKey: "camY") as? Double ?? 0.62
        camW = d.object(forKey: "camW") as? Double ?? 0.9
        camH = d.object(forKey: "camH") as? Double ?? 0.3
        camZoom = d.object(forKey: "camZoom") as? Double ?? 1

        // Versiyon 1'deki "orijinali göster" ayarını yeni gösterim moduna taşı.
        let legacyShowOriginal = d.object(forKey: "showOriginal") as? Bool ?? true
        displayMode = DisplayMode(rawValue: d.string(forKey: "displayMode") ?? "")
            ?? (legacyShowOriginal ? .both : .translation)
        let storedLines = d.object(forKey: "lines") as? Int ?? 3
        lines = min(max(storedLines, AppSettings.linesRange.lowerBound), AppSettings.linesRange.upperBound)
        fontSize = d.object(forKey: "fontSize") as? Double ?? 58
        centered = d.object(forKey: "centered") as? Bool ?? false
        textColor = SubtitleColor(rawValue: d.string(forKey: "textColor") ?? "") ?? .white
        boxBackground = BoxBackground(rawValue: d.string(forKey: "boxBackground") ?? "") ?? .black
        fontStyle = FontStyleChoice(rawValue: d.string(forKey: "fontStyle") ?? "") ?? .standard
        boldText = d.object(forKey: "boldText") as? Bool ?? true

        appTheme = AppTheme(rawValue: d.string(forKey: "appTheme") ?? "") ?? .dark
        accent = AccentChoice(rawValue: d.string(forKey: "accent") ?? "") ?? .blue

        speakEnabled = d.object(forKey: "speakEnabled") as? Bool ?? false
        speakTarget = SpeakTarget(rawValue: d.string(forKey: "speakTarget") ?? "") ?? .translation
        voiceID = d.string(forKey: "voiceID") ?? ""
        speechRate = d.object(forKey: "speechRate") as? Double ?? 0.5

        historyEnabled = d.object(forKey: "historyEnabled") as? Bool ?? true
        onboardingDone = d.object(forKey: "onboardingDone") as? Bool ?? false
    }

    func changeLines(by delta: Int) {
        guard !boxLocked else { return }
        lines = min(max(lines + delta, AppSettings.linesRange.lowerBound), AppSettings.linesRange.upperBound)
    }

    /// Kamera modunda okunacak alan (sol üst köşe başlangıçlı, 0–1).
    var cameraRect: CGRect {
        get { CGRect(x: camX, y: camY, width: camW, height: camH) }
        set {
            camX = Double(newValue.minX); camY = Double(newValue.minY)
            camW = Double(newValue.width); camH = Double(newValue.height)
        }
    }

    /// Sık kullanılan ayar kombinasyonları.
    enum Preset: String, CaseIterable, Identifiable {
        case youtubeCaptions, videoSpeech, song, englishOnly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .youtubeCaptions: return "YouTube altyazı"
            case .videoSpeech: return "Video sesi"
            case .song: return "Şarkı"
            case .englishOnly: return "Sadece orijinal"
            }
        }
        var icon: String {
            switch self {
            case .youtubeCaptions: return "captions.bubble"
            case .videoSpeech: return "waveform"
            case .song: return "music.note"
            case .englishOnly: return "text.alignleft"
            }
        }
        var detail: String {
            switch self {
            case .youtubeCaptions: return "Ekrandaki altyazıyı okur, sadece Türkçesini gösterir."
            case .videoSpeech: return "Konuşmayı dinler, orijinal + çeviri gösterir."
            case .song: return "Şarkı sözlerini Gemini ile dinler (anahtar gerekir)."
            case .englishOnly: return "Çeviri yapmadan canlı altyazı gösterir."
            }
        }
    }

    func apply(_ p: Preset) {
        switch p {
        case .youtubeCaptions:
            inputSource = .screen
            displayMode = .translation
            if lines > 3 { lines = 2 }
        case .videoSpeech:
            inputSource = .audio
            asr = .apple
            if sourceLang == "auto" { sourceLang = "en-US" }
            displayMode = .both
        case .song:
            inputSource = .audio
            asr = .gemini
            displayMode = .both
        case .englishOnly:
            displayMode = .original
        }
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

    init(_ s: AppSettings, mode: RunMode = .screen) {
        sourceLang = s.sourceLang
        targetLang = s.targetLang
        asr = s.asr
        translator = s.translator
        input = mode == .camera ? s.camInput : s.inputSource
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
    /// Seslendirmede kullanılacak dil kodları
    var speechSourceLanguage: String { sourceIsAuto ? "en-US" : sourceLang }
    var speechTargetLanguage: String { Languages.appleLanguageID(targetLang) }
}
