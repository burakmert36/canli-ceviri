import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var s: AppSettings
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var showAdvanced = false

    private var needsGemini: Bool { s.asr == .gemini || s.translator == .gemini }
    private var needsOpenAI: Bool { s.asr == .openai || s.translator == .openai }
    private var needsClaude: Bool { s.translator == .claude }

    var body: some View {
        NavigationStack {
            Form {
                controlSection
                languageSection
                engineSection
                if needsGemini || needsOpenAI || needsClaude { keySection }
                appearanceSection
                advancedSection
                helpSection
            }
            .navigationTitle("Canlı Çeviri")
            .navigationBarTitleDisplayMode(.inline)
        }
        .translationTask(downloadConfig) { session in
            do { try await session.prepareTranslation() } catch {}
        }
        .onChange(of: s.asr) { _, newValue in
            if newValue == .apple && s.sourceLang == "auto" { s.sourceLang = "en-US" }
        }
    }

    // MARK: Bölümler

    private var controlSection: some View {
        Section {
            OverlayPreview(layer: engine.pip.displayLayer)
                .aspectRatio(s.boxShape.aspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))

            Button {
                engine.running ? engine.stop() : engine.start()
            } label: {
                Label(engine.running ? "Durdur" : "Başlat",
                      systemImage: engine.running ? "stop.fill" : "play.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.running ? .red : .blue)

            HStack(spacing: 10) {
                Circle()
                    .fill(engine.audioConnected ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(engine.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                BroadcastButton()
                    .frame(width: 40, height: 40)
            }

            if engine.running && !engine.boxVisible {
                Button {
                    engine.showBox()
                } label: {
                    Label("Kutuyu tekrar göster", systemImage: "pip.enter")
                }
            }
        } footer: {
            Text("Başlat'a dokun → açılan pencerede “Yayını Başlat” → sonra TikTok, YouTube vb.'ye geç. Siyah kutu her uygulamanın üstünde kalır; sürükleyip iki parmakla büyütebilirsin. Sağdaki ⏺ simgesi ses yakalamayı elle açar.")
        }
    }

    private var languageSection: some View {
        Section("Diller") {
            Picker("Videonun dili", selection: $s.sourceLang) {
                ForEach(Languages.sources(for: s.asr)) { Text($0.name).tag($0.id) }
            }
            Picker("Çeviri dili", selection: $s.targetLang) {
                ForEach(Languages.targets) { Text($0.name).tag($0.id) }
            }
        }
    }

    private var engineSection: some View {
        Section {
            Picker("Ses tanıma", selection: $s.asr) {
                ForEach(ASREngine.allCases) { Text($0.title).tag($0) }
            }
            Picker("Çeviri motoru", selection: $s.translator) {
                ForEach(TranslatorEngine.allCases) { Text($0.title).tag($0) }
            }
            if s.translator == .apple {
                Button("Apple Çeviri dil paketini indir") {
                    if s.sourceLang != "auto" {
                        downloadConfig = TranslationSession.Configuration(
                            source: Locale.Language(identifier: Languages.appleLanguageID(s.sourceLang)),
                            target: Locale.Language(identifier: Languages.appleLanguageID(s.targetLang)))
                    }
                }
            }
        } header: {
            Text("Motor")
        } footer: {
            Text(engineFooter)
        }
    }

    private var engineFooter: String {
        var lines: [String] = []
        switch s.asr {
        case .apple:
            lines.append("Apple ses tanıma: en hızlı ve tamamen ücretsiz; videonun dilini seçmen gerekir.")
        case .gemini, .openai:
            lines.append("Bulut ses tanıma: dili kendisi algılar, şarkı ve gürültülü seslerde daha iyidir; 3–7 sn gecikmeli çalışır ve API kullanımı kadar ücretlidir.")
        }
        switch s.translator {
        case .google: lines.append("Google Çeviri: ücretsiz, anahtar gerekmez.")
        case .apple: lines.append("Apple Çeviri: internetsiz çalışır; önce dil paketini indir.")
        case .gemini, .openai, .claude: lines.append("Yapay zekâ çevirisi: en doğal sonuç; kendi API anahtarınla çalışır.")
        }
        return lines.joined(separator: "\n")
    }

    private var keySection: some View {
        Section {
            if needsGemini {
                SecureField("Gemini API anahtarı", text: $s.geminiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("Ücretsiz Gemini anahtarı al → aistudio.google.com",
                     destination: URL(string: "https://aistudio.google.com/apikey")!)
                    .font(.footnote)
            }
            if needsOpenAI {
                SecureField("OpenAI API anahtarı", text: $s.openaiKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("OpenAI anahtarı al → platform.openai.com",
                     destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.footnote)
            }
            if needsClaude {
                SecureField("Claude API anahtarı", text: $s.claudeKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("Claude anahtarı al → console.anthropic.com",
                     destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.footnote)
            }
        } header: {
            Text("API anahtarları")
        } footer: {
            Text("Anahtarlar yalnızca bu telefonda saklanır ve sadece ilgili şirkete gönderilir.")
        }
    }

    private var appearanceSection: some View {
        Section("Görünüm") {
            VStack(alignment: .leading) {
                Text("Yazı boyutu: \(Int(s.fontSize))")
                Slider(value: $s.fontSize, in: 36...100, step: 2)
            }
            Toggle("Orijinal metni de göster", isOn: $s.showOriginal)
            Picker("Kutu şekli", selection: $s.boxShape) {
                ForEach(BoxShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup("Gelişmiş (model adları)", isExpanded: $showAdvanced) {
                modelField("Gemini modeli", text: $s.geminiModel, placeholder: AppSettings.defaultGeminiModel)
                modelField("ChatGPT modeli", text: $s.openaiModel, placeholder: AppSettings.defaultOpenAIModel)
                modelField("OpenAI ses modeli", text: $s.openaiASRModel, placeholder: AppSettings.defaultOpenAIASRModel)
                modelField("Claude modeli", text: $s.claudeModel, placeholder: AppSettings.defaultClaudeModel)
                Button("Varsayılanlara dön") {
                    s.geminiModel = AppSettings.defaultGeminiModel
                    s.openaiModel = AppSettings.defaultOpenAIModel
                    s.openaiASRModel = AppSettings.defaultOpenAIASRModel
                    s.claudeModel = AppSettings.defaultClaudeModel
                }
            }
        }
    }

    private func modelField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())
        }
    }

    private var helpSection: some View {
        Section("İpuçları") {
            Label("Kutuya dokununca çıkan ⏸ ile çeviriyi dondurabilirsin.", systemImage: "pause.circle")
            Label("Kutuyu ✕ ile kapatmak çeviriyi ve ses yakalamayı durdurur.", systemImage: "xmark.circle")
            Label("Apple Music, Netflix gibi korumalı içeriklerin sesini iOS yakalatmaz.", systemImage: "lock")
            Label("Ayarlar değişince çeviri durmadan yeni ayara geçer.", systemImage: "gearshape")
        }
        .font(.footnote)
    }
}
