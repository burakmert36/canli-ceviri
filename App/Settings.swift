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
    case google, apple, appleAI, gemini, openai, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google Çeviri (ücretsiz)"
        case .apple: return "Apple Çeviri (cihazda, ücretsiz)"
        case .appleAI: return "Apple Zekâ (cihazda, ücretsiz)"
        case .gemini: return "Gemini"
        case .openai: return "ChatGPT (OpenAI)"
        case .claude: return "Claude"
        }
    }
    var isLLM: Bool { self == .gemini || self == .openai || self == .claude || self == .appleAI }
}

/// Kutudaki ⏪ ⏩ düğmelerinin görevi.
enum PiPButtonAction: String, CaseIterable, Identifiable {
    case lines, language, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .lines: return "Satır sayısı"
        case .language: return "Dil değiştir"
        case .off: return "Kapalı"
        }
    }
}

/// İzlenen içeriğin türü: yapay zekâ çevirisine bağlam olarak verilir.
enum ContentKind: String, CaseIterable, Identifiable {
    case general, game, movie, music, news, education
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "Genel"
        case .game: return "Oyun"
        case .movie: return "Film / dizi"
        case .music: return "Şarkı"
        case .news: return "Haber / belgesel"
        case .education: return "Eğitim / teknik"
        }
    }
    var icon: String {
        switch self {
        case .general: return "sparkles"
        case .game: return "gamecontroller.fill"
        case .movie: return "film.fill"
        case .music: return "music.note"
        case .news: return "newspaper.fill"
        case .education: return "graduationcap.fill"
        }
    }
    /// Yapay zekâ istemine eklenen açıklama.
    var promptHint: String? {
        switch self {
        case .general: return nil
        case .game: return "The content is a video game (cutscene dialogue, characters talking, game terms). Keep game terminology, character and place names; street slang should stay slangy."
        case .movie: return "The content is a film or TV series dialogue. Write short, natural subtitle lines that match each character's voice."
        case .music: return "The content is song lyrics. Translate the meaning poetically but faithfully; keep it short and singable, do not explain."
        case .news: return "The content is news or a documentary. Use clear, neutral, accurate wording and correct names of people, places and organisations."
        case .education: return "The content is educational or technical. Keep technical terms precise (leave well-known English terms if they are commonly used)."
        }
    }
}

/// Kaynak → hedef dil çifti (hızlı dil değiştirme için).
struct LangPair: Hashable, Identifiable {
    let source: String
    let target: String
    var id: String { key }
    var key: String { source + ">" + target }

    init(source: String, target: String) {
        self.source = source
        self.target = target
    }

    init?(key: String) {
        let parts = key.split(separator: ">", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, Languages.source(parts[0]) != nil, Languages.target(parts[1]) != nil else { return nil }
        source = parts[0]
        target = parts[1]
    }

    /// "İngilizce → Türkçe" gibi kısa ad.
    var title: String {
        let s = Languages.source(source)?.english ?? source
        let t = Languages.target(target)?.english ?? target
        return "\(Languages.shortName(source: s, id: source)) → \(Languages.shortName(target: t, id: target))"
    }
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

/// Ekran modunda altyazı alanı nasıl belirlenir?
enum OCRAreaMode: String, CaseIterable, Identifiable {
    case manual, auto
    var id: String { rawValue }
    var title: String { self == .manual ? "Seçtiğim alan" : "Otomatik (deneysel)" }
}

/// Bir yapay zekâ sağlayıcısının seçilebilir modeli.
struct ModelOption: Identifiable, Hashable {
    let id: String
    let note: String
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

/// Sesli okurken diğer uygulamaların (YouTube vb.) sesi ne olsun?
enum DuckMode: String, CaseIterable, Identifiable {
    case whileSpeaking, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whileSpeaking: return "Konuşurken kıs"
        case .always: return "Hep kısık"
        case .never: return "Kısma"
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
    /// Kutudaki ⏪ ⏩ düğmeleri: satır sayısı, dil değiştirme ya da kapalı.
    @Published var pipButtons: PiPButtonAction { didSet { d.set(pipButtons.rawValue, forKey: "pipButtons") } }
    /// Altyazı alanı: elle seçilen (dikey ve yatay için ayrı) ya da otomatik.
    @Published var ocrAreaMode: OCRAreaMode { didSet { d.set(ocrAreaMode.rawValue, forKey: "ocrAreaMode") } }
    @Published var portraitArea: CGRect { didSet { d.set(Self.encode(portraitArea), forKey: "portraitArea") } }
    @Published var landscapeArea: CGRect { didSet { d.set(Self.encode(landscapeArea), forKey: "landscapeArea") } }
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
    /// Sesli okurken videonun sesini kıs (iOS "ducking": telefonun ses düzeyi değişmez).
    @Published var duckMode: DuckMode { didSet { d.set(duckMode.rawValue, forKey: "duckMode") } }

    // Performans
    @Published var batteryMode: BatteryMode { didSet { d.set(batteryMode.rawValue, forKey: "batteryMode") } }
    /// Cümle bitmeden (konuşurken) çeviriyi güncelle. Kapalıysa yalnızca biten cümleler çevrilir.
    @Published var liveTranslation: Bool { didSet { d.set(liveTranslation, forKey: "liveTranslation") } }
    /// Hibrit: konuşma sürerken ücretsiz hızlı motor, cümle bitince seçilen yapay zekâ çevirir.
    @Published var hybridLive: Bool { didSet { d.set(hybridLive, forKey: "hybridLive") } }
    /// İzlenen içeriğin türü (yapay zekâ çevirisine bağlam).
    @Published var contentKind: ContentKind { didSet { d.set(contentKind.rawValue, forKey: "contentKind") } }
    /// Son kullanılan dil çiftleri ("en-US>tr" biçiminde, en yenisi başta).
    @Published var recentPairs: [String] { didSet { d.set(recentPairs, forKey: "recentPairs") } }

    // Diğer
    @Published var historyEnabled: Bool { didSet { d.set(historyEnabled, forKey: "historyEnabled") } }
    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

    static let linesRange = 1...8

    /// Dikey YouTube'da üstteki oynatıcı; yatay tam ekranda alttaki altyazı bölgesi.
    static let defaultPortraitArea = CGRect(x: 0, y: 0.05, width: 1, height: 0.32)
    static let defaultLandscapeArea = CGRect(x: 0.08, y: 0.58, width: 0.84, height: 0.4)

    private static func encode(_ r: CGRect) -> [Double] {
        [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
    }
    private static func decode(_ a: [Any]?) -> CGRect? {
        guard let v = a as? [Double], v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    static let geminiModels = [
        ModelOption(id: "gemini-3.5-flash-lite", note: "En hızlı ve ucuz (önerilen)"),
        ModelOption(id: "gemini-3.1-flash-lite", note: "Hızlı"),
        ModelOption(id: "gemini-3.6-flash", note: "Dengeli"),
        ModelOption(id: "gemini-3.8-flash", note: "En kaliteli"),
    ]
    static let openaiModels = [
        ModelOption(id: "gpt-5.4-nano", note: "En hızlı ve ucuz (önerilen)"),
        ModelOption(id: "gpt-5.4-mini", note: "Dengeli"),
        ModelOption(id: "gpt-5.6-luna", note: "Yeni nesil, hızlı"),
        ModelOption(id: "gpt-5.6-terra", note: "Yüksek kalite"),
    ]
    static let openaiASRModels = [
        ModelOption(id: "gpt-4o-mini-transcribe", note: "Hızlı (önerilen)"),
        ModelOption(id: "gpt-4o-transcribe", note: "Daha doğru"),
    ]
    static let claudeModels = [
        ModelOption(id: "claude-haiku-5-5", note: "Hızlı ve ucuz (önerilen)"),
        ModelOption(id: "claude-sonnet-5-5", note: "Yüksek kalite"),
    ]

    static let defaultGeminiModel = "gemini-3.5-flash-lite"
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
        if let raw = d.string(forKey: "pipButtons"), let b = PiPButtonAction(rawValue: raw) {
            pipButtons = b
        } else {
            // Eski "⏪ ⏩ ile satır sayısı" ayarını taşı.
            pipButtons = (d.object(forKey: "pipButtonsResize") as? Bool ?? true) ? .lines : .off
        }
        ocrAreaMode = OCRAreaMode(rawValue: d.string(forKey: "ocrAreaMode") ?? "") ?? .manual
        portraitArea = Self.decode(d.array(forKey: "portraitArea")) ?? AppSettings.defaultPortraitArea
        landscapeArea = Self.decode(d.array(forKey: "landscapeArea")) ?? AppSettings.defaultLandscapeArea
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
        duckMode = DuckMode(rawValue: d.string(forKey: "duckMode") ?? "") ?? .whileSpeaking

        batteryMode = BatteryMode(rawValue: d.string(forKey: "batteryMode") ?? "") ?? .auto
        liveTranslation = d.object(forKey: "liveTranslation") as? Bool ?? true
        hybridLive = d.object(forKey: "hybridLive") as? Bool ?? true
        contentKind = ContentKind(rawValue: d.string(forKey: "contentKind") ?? "") ?? .general
        recentPairs = (d.stringArray(forKey: "recentPairs") ?? []).filter { LangPair(key: $0) != nil }
        historyEnabled = d.object(forKey: "historyEnabled") as? Bool ?? true
        onboardingDone = d.object(forKey: "onboardingDone") as? Bool ?? false
        #if DEBUG
        applyTestingArguments()
        #endif
    }

    #if DEBUG
    /// Otomatik testlerde (UI testleri) tanıtımı atlamak ve temiz ayarlarla başlamak için.
    private func applyTestingArguments() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--reset-settings") {
            for key in d.dictionaryRepresentation().keys { d.removeObject(forKey: key) }
            onboardingDone = false
        }
        if args.contains("--skip-onboarding") { onboardingDone = true }
    }
    #endif

    var pipButtonsVisible: Bool {
        switch pipButtons {
        case .off: return false
        case .lines: return !boxLocked
        case .language: return true
        }
    }

    // MARK: Hızlı dil değiştirme

    static let defaultPairs = ["en-US>tr", "tr-TR>en", "de-DE>tr", "es-ES>tr"]

    var currentPair: LangPair { LangPair(source: sourceLang, target: targetLang) }

    /// Bu dil çifti mevcut motorlarla kullanılabilir mi?
    func isUsable(_ p: LangPair, input: InputSource? = nil) -> Bool {
        guard p.source == "auto" else { return p.source != "" }
        let i = input ?? inputSource
        if i == .audio && asr == .apple { return false }
        if translator == .apple && displayMode != .original { return false }
        return true
    }

    /// Hızlı değiştirme listesi: son kullanılanlar, azsa yaygın çiftlerle tamamlanır.
    func quickPairs(input: InputSource? = nil) -> [LangPair] {
        var out: [LangPair] = []
        for key in recentPairs + Self.defaultPairs {
            guard let p = LangPair(key: key), isUsable(p, input: input), !out.contains(p) else { continue }
            if out.count >= 4 && !recentPairs.contains(key) { break }
            out.append(p)
            if out.count >= 6 { break }
        }
        return out
    }

    /// Şu anki dil çiftini "son kullanılanlar"ın başına yazar.
    func rememberCurrentPair() {
        let k = currentPair.key
        guard LangPair(key: k) != nil else { return }
        var list = recentPairs.filter { $0 != k }
        list.insert(k, at: 0)
        if list.count > 5 { list = Array(list.prefix(5)) }
        if list != recentPairs { recentPairs = list }
    }

    func apply(_ p: LangPair) {
        if sourceLang != p.source { sourceLang = p.source }
        if targetLang != p.target { targetLang = p.target }
    }

    /// Listede bir sonraki (ya da önceki) dil çiftine geçer.
    @discardableResult
    func cycleLanguagePair(forward: Bool = true, input: InputSource? = nil) -> LangPair? {
        let list = quickPairs(input: input)
        guard list.count >= 2 else { return nil }
        let idx = list.firstIndex(of: currentPair)
        let next: Int
        if let i = idx {
            next = (i + (forward ? 1 : -1) + list.count) % list.count
        } else {
            next = forward ? 0 : list.count - 1
        }
        let p = list[next]
        apply(p)
        return p
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
    var hybrid: Bool
    var contentKind: ContentKind

    init(_ s: AppSettings, mode: RunMode = .screen) {
        sourceLang = s.sourceLang
        targetLang = s.targetLang
        asr = s.asr
        translator = s.translator
        input = mode == .camera ? s.camInput : s.inputSource
        displayMode = s.displayMode
        hybrid = s.hybridLive
        contentKind = s.contentKind
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
    /// Konuşma sürerken (canlı kısım) ücretsiz hızlı motor mu kullanılsın?
    var hybridActive: Bool { hybrid && translator.isLLM }
    var sourceEnglishName: String { Languages.source(sourceLang)?.english ?? "the original language" }
    var targetEnglishName: String { Languages.target(targetLang)?.english ?? targetLang }
    /// Seslendirmede kullanılacak dil kodları
    var speechSourceLanguage: String { sourceIsAuto ? "en-US" : sourceLang }
    var speechTargetLanguage: String { Languages.appleLanguageID(targetLang) }
}
