import SwiftUI
import Translation

extension TranslatorEngine {
    var shortName: String {
        switch self {
        case .google: return "Google"
        case .apple: return "iPhone Çeviri"
        case .appleAI: return "Apple Zekâ"
        case .gemini: return "Gemini"
        case .openai: return "ChatGPT"
        case .claude: return "Claude"
        }
    }
    var icon: String {
        switch self {
        case .google: return "globe"
        case .apple: return "apple.logo"
        case .appleAI: return "sparkles"
        case .gemini: return "sparkle"
        case .openai: return "bubble.left.and.text.bubble.right"
        case .claude: return "asterisk"
        }
    }
    var needsKey: Bool { self == .gemini || self == .openai || self == .claude }
}

/// Çeviri motorunu seçmek için yatay kartlar. Anahtar gerekiyorsa ayar sayfası açılır.
struct TranslatorPicker: View {
    @EnvironmentObject private var s: AppSettings
    @State private var sheetFor: TranslatorEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TranslatorEngine.allCases) { e in
                        Button {
                            s.translator = e
                            if e.needsKey && key(e).isEmpty { sheetFor = e }
                        } label: {
                            chip(e)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(e.shortName + ", " + status(e).0)
                        .accessibilityAddTraits(s.translator == e ? .isSelected : [])
                        .accessibilityIdentifier("engine-" + e.rawValue)
                    }
                }
                .padding(.vertical, 2)
            }
            Button {
                sheetFor = s.translator
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                    Text(detailLine(s.translator)).lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Ayarla").fontWeight(.semibold)
                }
                .font(.footnote)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("engine-configure")
        }
        .sheet(item: $sheetFor) { e in
            ProviderSheet(engine: e).environmentObject(s)
        }
    }

    private func key(_ e: TranslatorEngine) -> String {
        switch e {
        case .gemini: return s.geminiKey
        case .openai: return s.openaiKey
        case .claude: return s.claudeKey
        default: return "x"
        }
    }

    private func status(_ e: TranslatorEngine) -> (String, Bool) {
        switch e {
        case .google: return ("Ücretsiz", true)
        case .apple:
            if #available(iOS 26.0, *) { return ("Ücretsiz · internetsiz", true) }
            return ("iOS 26 gerekli", false)
        case .appleAI:
            return TranslationService.appleIntelligenceAvailable ? ("Ücretsiz · cihazda", true) : ("Kapalı / uyumsuz", false)
        case .gemini, .openai, .claude:
            return key(e).isEmpty ? ("Anahtar gerekli", false) : ("Hazır", true)
        }
    }

    private func detailLine(_ e: TranslatorEngine) -> String {
        switch e {
        case .google: return "Google Çeviri · anahtarsız"
        case .apple: return "iPhone'un kendi çevirmeni · dil paketi"
        case .appleAI: return "Apple Zekâ · cihaz içi yapay zekâ"
        case .gemini: return "Model: \(s.geminiModel)"
        case .openai: return "Model: \(s.openaiModel)"
        case .claude: return "Model: \(s.claudeModel)"
        }
    }

    private func chip(_ e: TranslatorEngine) -> some View {
        let selected = s.translator == e
        let (text, ok) = status(e)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: e.icon).font(.footnote.weight(.semibold))
                Text(e.shortName).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            Text(text)
                .font(.caption2)
                .foregroundStyle(ok ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? AnyShapeStyle(TintShapeStyle().opacity(0.16)) : AnyShapeStyle(Color(.tertiarySystemFill)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 1.5)
        )
    }
}

/// Ses tanıma motoru seçici (ses modunda).
struct ASRPicker: View {
    @EnvironmentObject private var s: AppSettings
    @State private var sheetFor: TranslatorEngine?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Ses tanıma", selection: $s.asr) {
                Text("Apple (ücretsiz)").tag(ASREngine.apple)
                Text("Gemini").tag(ASREngine.gemini)
                Text("OpenAI").tag(ASREngine.openai)
            }
            .pickerStyle(.segmented)
            if s.asr == .gemini && s.geminiKey.isEmpty {
                Button("Gemini anahtarı gerekli → Ayarla") { sheetFor = .gemini }.font(.footnote).buttonStyle(.borderless)
            } else if s.asr == .openai && s.openaiKey.isEmpty {
                Button("OpenAI anahtarı gerekli → Ayarla") { sheetFor = .openai }.font(.footnote).buttonStyle(.borderless)
            }
        }
        .sheet(item: $sheetFor) { e in ProviderSheet(engine: e).environmentObject(s) }
    }
}

/// Bir çeviri sağlayıcısının ayarları: anahtar, model, dil paketi.
struct ProviderSheet: View {
    let engine: TranslatorEngine
    @EnvironmentObject private var s: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var customModel = ""

    var body: some View {
        NavigationStack {
            Form {
                switch engine {
                case .google:
                    Section {
                        Text("Ücretsizdir ve anahtar gerektirmez. Hızlıdır; çok yoğun kullanımda Google geçici olarak yavaşlatırsa uygulama otomatik olarak iPhone Çeviri'ye geçer.")
                    }
                case .apple:
                    Section {
                        Text("iPhone'un kendi çevirmeni. İnternetsiz ve ücretsiz çalışır; önce dil paketini indirmek gerekir. Videonun dilini seçmen gerekir (otomatik algılama yok).")
                        Button("Dil paketini indir (\(Languages.source(s.sourceLang)?.name ?? "kaynak") → \(Languages.target(s.targetLang)?.name ?? "hedef"))") {
                            if s.sourceLang != "auto" {
                                downloadConfig = TranslationSession.Configuration(
                                    source: Locale.Language(identifier: Languages.appleLanguageID(s.sourceLang)),
                                    target: Locale.Language(identifier: Languages.appleLanguageID(s.targetLang)))
                            }
                        }
                        .disabled(s.sourceLang == "auto")
                    } footer: {
                        Text("Paketler Ayarlar > Uygulamalar > Çeviri > İndirilen Diller bölümünden de yönetilebilir.")
                    }
                case .appleAI:
                    Section {
                        Label(TranslationService.appleIntelligenceAvailable ? "Bu cihazda hazır" : "Şu an kullanılamıyor",
                              systemImage: TranslationService.appleIntelligenceAvailable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        Text("iPhone'un cihaz içi yapay zekâsı (Apple Intelligence). Ücretsiz, internetsiz ve cümlenin bağlamını anlar. Açmak için: Ayarlar > Apple Intelligence ve Siri. Desteklemediği bir dil ya da içerikte uygulama otomatik olarak Google'a geçer.")
                    }
                case .gemini:
                    keySection(title: "Gemini API anahtarı", key: $s.geminiKey,
                               link: "https://aistudio.google.com/apikey", linkTitle: "Ücretsiz anahtar al → aistudio.google.com")
                    modelSection(selection: $s.geminiModel, options: AppSettings.geminiModels)
                case .openai:
                    keySection(title: "OpenAI API anahtarı", key: $s.openaiKey,
                               link: "https://platform.openai.com/api-keys", linkTitle: "Anahtar al → platform.openai.com")
                    modelSection(selection: $s.openaiModel, options: AppSettings.openaiModels)
                    Section("Ses tanıma modeli (OpenAI ile dinlerken)") {
                        Picker("Ses modeli", selection: $s.openaiASRModel) {
                            ForEach(AppSettings.openaiASRModels) { m in
                                Text("\(m.id) · \(m.note)").tag(m.id)
                            }
                        }
                    }
                case .claude:
                    keySection(title: "Claude API anahtarı", key: $s.claudeKey,
                               link: "https://console.anthropic.com/settings/keys", linkTitle: "Anahtar al → console.anthropic.com")
                    modelSection(selection: $s.claudeModel, options: AppSettings.claudeModels)
                }
                Section {
                    Button {
                        s.translator = engine
                        dismiss()
                    } label: {
                        Label(s.translator == engine ? "Kullanılıyor" : "Bu motoru kullan",
                              systemImage: s.translator == engine ? "checkmark.circle.fill" : "circle")
                    }
                    .disabled(s.translator == engine)
                }
            }
            .navigationTitle(engine.shortName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Bitti") { dismiss() }.fontWeight(.semibold) }
            }
        }
        .translationTask(downloadConfig) { session in
            do { try await session.prepareTranslation() } catch {}
        }
    }

    private func keySection(title: String, key: Binding<String>, link: String, linkTitle: String) -> some View {
        Section {
            SecureField(title, text: key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let url = URL(string: link) {
                Link(linkTitle, destination: url).font(.footnote)
            }
        } header: {
            Text("Anahtar")
        } footer: {
            Text("Anahtar yalnızca bu cihazda saklanır ve sadece ilgili şirkete gönderilir. Kullanım kadar ücretlendirilir (Gemini'nin ücretsiz kotası vardır).")
        }
    }

    private func modelSection(selection: Binding<String>, options: [ModelOption]) -> some View {
        Section {
            Picker("Model", selection: selection) {
                ForEach(options) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.id)
                        Text(m.note).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
                if !options.contains(where: { $0.id == selection.wrappedValue }) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            HStack {
                TextField("Başka model adı yaz", text: $customModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                Button("Kullan") {
                    let t = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { selection.wrappedValue = t; customModel = "" }
                }
                .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Hızlı modeller altyazı gibi kısa cümleler için idealdir; daha kaliteli modeller daha doğal çevirir ama biraz daha yavaş ve pahalıdır.")
        }
    }
}
