import Foundation

struct Lang: Identifiable, Hashable {
    let id: String       // kaynak için konuşma tanıma yerel ayarı (en-US), hedef için Google kodu (tr)
    let name: String     // Türkçe görünen ad
    let english: String  // yapay zekâ istemlerinde kullanılan İngilizce ad
}

enum Languages {
    static let auto = Lang(id: "auto", name: "Otomatik algıla", english: "the detected language")

    static let sources: [Lang] = [
        Lang(id: "en-US", name: "İngilizce (ABD)", english: "English"),
        Lang(id: "en-GB", name: "İngilizce (İngiltere)", english: "English"),
        Lang(id: "tr-TR", name: "Türkçe", english: "Turkish"),
        Lang(id: "de-DE", name: "Almanca", english: "German"),
        Lang(id: "fr-FR", name: "Fransızca", english: "French"),
        Lang(id: "es-ES", name: "İspanyolca (İspanya)", english: "Spanish"),
        Lang(id: "es-MX", name: "İspanyolca (Meksika)", english: "Spanish"),
        Lang(id: "it-IT", name: "İtalyanca", english: "Italian"),
        Lang(id: "pt-BR", name: "Portekizce (Brezilya)", english: "Portuguese"),
        Lang(id: "pt-PT", name: "Portekizce (Portekiz)", english: "Portuguese"),
        Lang(id: "ru-RU", name: "Rusça", english: "Russian"),
        Lang(id: "uk-UA", name: "Ukraynaca", english: "Ukrainian"),
        Lang(id: "ar-SA", name: "Arapça", english: "Arabic"),
        Lang(id: "ja-JP", name: "Japonca", english: "Japanese"),
        Lang(id: "ko-KR", name: "Korece", english: "Korean"),
        Lang(id: "zh-CN", name: "Çince (Mandarin)", english: "Chinese"),
        Lang(id: "zh-TW", name: "Çince (Tayvan)", english: "Chinese"),
        Lang(id: "yue-CN", name: "Kantonca", english: "Cantonese"),
        Lang(id: "hi-IN", name: "Hintçe", english: "Hindi"),
        Lang(id: "nl-NL", name: "Felemenkçe", english: "Dutch"),
        Lang(id: "pl-PL", name: "Lehçe", english: "Polish"),
        Lang(id: "sv-SE", name: "İsveççe", english: "Swedish"),
        Lang(id: "nb-NO", name: "Norveççe", english: "Norwegian"),
        Lang(id: "da-DK", name: "Danca", english: "Danish"),
        Lang(id: "fi-FI", name: "Fince", english: "Finnish"),
        Lang(id: "el-GR", name: "Yunanca", english: "Greek"),
        Lang(id: "he-IL", name: "İbranice", english: "Hebrew"),
        Lang(id: "id-ID", name: "Endonezce", english: "Indonesian"),
        Lang(id: "ms-MY", name: "Malayca", english: "Malay"),
        Lang(id: "th-TH", name: "Tayca", english: "Thai"),
        Lang(id: "vi-VN", name: "Vietnamca", english: "Vietnamese"),
        Lang(id: "ro-RO", name: "Rumence", english: "Romanian"),
        Lang(id: "hu-HU", name: "Macarca", english: "Hungarian"),
        Lang(id: "cs-CZ", name: "Çekçe", english: "Czech"),
    ]

    static let targets: [Lang] = [
        Lang(id: "tr", name: "Türkçe", english: "Turkish"),
        Lang(id: "en", name: "İngilizce", english: "English"),
        Lang(id: "de", name: "Almanca", english: "German"),
        Lang(id: "fr", name: "Fransızca", english: "French"),
        Lang(id: "es", name: "İspanyolca", english: "Spanish"),
        Lang(id: "it", name: "İtalyanca", english: "Italian"),
        Lang(id: "pt", name: "Portekizce", english: "Portuguese"),
        Lang(id: "ru", name: "Rusça", english: "Russian"),
        Lang(id: "uk", name: "Ukraynaca", english: "Ukrainian"),
        Lang(id: "ar", name: "Arapça", english: "Arabic"),
        Lang(id: "az", name: "Azerbaycanca", english: "Azerbaijani"),
        Lang(id: "fa", name: "Farsça", english: "Persian"),
        Lang(id: "ja", name: "Japonca", english: "Japanese"),
        Lang(id: "ko", name: "Korece", english: "Korean"),
        Lang(id: "zh-CN", name: "Çince (Basitleştirilmiş)", english: "Simplified Chinese"),
        Lang(id: "zh-TW", name: "Çince (Geleneksel)", english: "Traditional Chinese"),
        Lang(id: "hi", name: "Hintçe", english: "Hindi"),
        Lang(id: "nl", name: "Felemenkçe", english: "Dutch"),
        Lang(id: "pl", name: "Lehçe", english: "Polish"),
        Lang(id: "sv", name: "İsveççe", english: "Swedish"),
        Lang(id: "el", name: "Yunanca", english: "Greek"),
        Lang(id: "id", name: "Endonezce", english: "Indonesian"),
        Lang(id: "ro", name: "Rumence", english: "Romanian"),
        Lang(id: "bg", name: "Bulgarca", english: "Bulgarian"),
        Lang(id: "ka", name: "Gürcüce", english: "Georgian"),
        Lang(id: "ku", name: "Kürtçe (Kurmanci)", english: "Kurdish (Kurmanji)"),
    ]

    static func sources(for asr: ASREngine) -> [Lang] {
        asr == .apple ? sources : [auto] + sources
    }

    static func source(_ id: String) -> Lang? {
        id == "auto" ? auto : sources.first { $0.id == id }
    }

    static func target(_ id: String) -> Lang? {
        targets.first { $0.id == id }
    }

    /// Google Çeviri kaynak kodu: "en-US" → "en", "zh-CN" → "zh-CN", "auto" → "auto"
    static func googleSource(_ id: String) -> String {
        switch id {
        case "auto": return "auto"
        case "zh-CN", "zh-TW": return id
        case "yue-CN": return "yue"
        case "he-IL": return "iw"
        case "nb-NO": return "no"
        default: return String(id.split(separator: "-").first ?? Substring(id))
        }
    }

    /// İki harfli ISO-639-1 dil kodu (OpenAI ses tanıma için). Otomatikte nil.
    static func isoCode(_ id: String) -> String? {
        if id == "auto" { return nil }
        if id.hasPrefix("yue") { return "zh" }
        if id.hasPrefix("nb") { return "no" }
        return String(id.split(separator: "-").first ?? Substring(id))
    }

    /// Kaynak ve hedef dili yer değiştirir (ör. İngilizce→Türkçe ⇄ Türkçe→İngilizce).
    static func swapped(source: String, target: String) -> (source: String, target: String)? {
        guard source != "auto" else { return nil }
        let newTarget = googleSource(source)
        guard Languages.target(newTarget) != nil else { return nil }
        let prefix = target.split(separator: "-").first.map(String.init) ?? target
        let newSource = sources.first(where: { $0.id == target })?.id
            ?? sources.first(where: { $0.id.hasPrefix(prefix + "-") })?.id
        guard let s = newSource else { return nil }
        return (s, newTarget)
    }

    /// Hızlı dil çifti etiketleri için kısa ad ("İngilizce (ABD)" → "İngilizce").
    static func shortName(source english: String, id: String) -> String {
        if id == "auto" { return "Otomatik" }
        let n = Languages.source(id)?.name ?? english
        return n.components(separatedBy: " (").first ?? n
    }

    static func shortName(target english: String, id: String) -> String {
        let n = Languages.target(id)?.name ?? english
        return n.components(separatedBy: " (").first ?? n
    }

    /// Apple Translation çerçevesi için dil kimliği.
    static func appleLanguageID(_ id: String) -> String {
        switch id {
        case "zh-CN": return "zh-Hans"
        case "zh-TW": return "zh-Hant"
        case "yue-CN": return "yue-Hant"
        default: return id
        }
    }
}
