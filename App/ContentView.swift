import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var s: AppSettings
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var showAdvanced = false

    private var translating: Bool { s.displayMode != .original }
    private var cloudASR: Bool { s.inputSource == .audio && s.asr != .apple }
    private var needsGemini: Bool { (cloudASR && s.asr == .gemini) || (translating && s.translator == .gemini) }
    private var needsOpenAI: Bool { (cloudASR && s.asr == .openai) || (translating && s.translator == .openai) }
    private var needsClaude: Bool { translating && s.translator == .claude }
    private var boxAspect: CGFloat {
        OverlayRenderer.aspect(mode: s.displayMode, lines: s.lines, fontSize: CGFloat(s.fontSize))
    }
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        NavigationStack {
            Form {
                controlSection
                sourceSection
                if s.inputSource == .screen { screenAreaSection }
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
        .onChange(of: s.asr) { _, _ in fixAutoLanguage() }
        .onChange(of: s.inputSource) { _, _ in fixAutoLanguage() }
    }

    private func fixAutoLanguage() {
        if s.inputSource == .audio && s.asr == .apple && s.sourceLang == "auto" { s.sourceLang = "en-US" }
    }

    // MARK: Kontrol

    private var controlSection: some View {
        Section {
            OverlayPreview(layer: engine.pip.displayLayer)
                .aspectRatio(boxAspect, contentMode: .fit)
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
            Text("Başlat'a dokun → açılan pencerede “Yayını Başlat” → sonra YouTube, TikTok vb.'ye geç. Sağdaki ⏺ simgesi ekran yayınını elle açar.")
        }
    }

    // MARK: Kaynak ve diller

    private var sourceSection: some View {
        Section {
            Picker("Çeviri kaynağı", selection: $s.inputSource) {
                ForEach(InputSource.allCases) { Text($0.title).tag($0) }
            }
            Picker("Videonun dili", selection: $s.sourceLang) {
                ForEach(Languages.sources(for: s.inputSource == .audio ? s.asr : .gemini)) {
                    Text($0.name).tag($0.id)
                }
            }
            if translating {
                Picker("Çeviri dili", selection: $s.targetLang) {
                    ForEach(Languages.targets) { Text($0.name).tag($0.id) }
                }
            }
        } header: {
            Text("Kaynak ve diller")
        } footer: {
            Text(s.inputSource == .audio
                 ? "Ses modu konuşmayı dinleyip yazıya döker; altyazısı olmayan videolar için."
                 : "Altyazı modu videodaki altyazıyı (ör. YouTube'da CC) okuyup çevirir. Konuşmacılar karışmaz, en doğru sonuç budur. Videoda altyazıyı açmayı unutma.")
        }
    }

    // MARK: Altyazı alanı

    private var screenAreaSection: some View {
        Section {
            if let img = engine.ocrPreview {
                ZStack {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                    GeometryReader { geo in
                        let h = geo.size.height
                        let topH: CGFloat = h * CGFloat(s.ocrTop)
                        let bandH: CGFloat = max(4, h * CGFloat(s.ocrBottom - s.ocrTop))
                        VStack(spacing: 0) {
                            Color.black.opacity(0.55).frame(height: topH)
                            Rectangle()
                                .strokeBorder(Color.yellow, lineWidth: 2)
                                .frame(height: bandH)
                            Color.black.opacity(0.55)
                        }
                    }
                }
                .aspectRatio(img.size, contentMode: .fit)
                .frame(maxHeight: 380)
                .frame(maxWidth: .infinity)
                if !engine.ocrPreviewText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bu alanda okunan:").font(.caption).foregroundStyle(.secondary)
                        Text(engine.ocrPreviewText).font(.footnote)
                    }
                }
            } else {
                Text("Önizleme için: Başlat → YouTube'da altyazılı bir video aç → birkaç saniye sonra bu uygulamaya geri dön. Son ekran görüntüsü burada görünür.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Üst sınır: %\(Int(s.ocrTop * 100))")
                Slider(value: Binding(get: { s.ocrTop },
                                      set: { s.ocrTop = min($0, s.ocrBottom - 0.05) }),
                       in: 0...0.95)
            }
            VStack(alignment: .leading) {
                Text("Alt sınır: %\(Int(s.ocrBottom * 100))")
                Slider(value: Binding(get: { s.ocrBottom },
                                      set: { s.ocrBottom = max($0, s.ocrTop + 0.05) }),
                       in: 0.05...1)
            }
            Button("Tüm ekranı oku (sıfırla)") {
                s.ocrTop = 0
                s.ocrBottom = 1
            }
        } header: {
            Text("Altyazı alanı")
        } footer: {
            Text("Sarı çerçeve altyazının çıktığı yeri kapsasın. Ekranda hep duran yazılar (başlık, menü) zaten otomatik elenir. Çeviri kutusunu bu alanın dışına koymak en temiz sonucu verir.")
        }
    }

    // MARK: Motor

    private var engineSection: some View {
        Section {
            if s.inputSource == .audio {
                Picker("Ses tanıma", selection: $s.asr) {
                    ForEach(ASREngine.allCases) { Text($0.title).tag($0) }
                }
            }
            if translating {
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
            }
        } header: {
            Text("Motor")
        } footer: {
            Text(engineFooter)
        }
    }

    private var engineFooter: String {
        var lines: [String] = []
        if s.inputSource == .audio {
            switch s.asr {
            case .apple:
                lines.append("Apple ses tanıma: en hızlı ve tamamen ücretsiz; videonun dilini seçmen gerekir.")
            case .gemini, .openai:
                lines.append("Bulut ses tanıma: dili kendisi algılar, şarkı ve gürültülü seslerde daha iyidir; 3–7 sn gecikmeli çalışır ve API kullanımı kadar ücretlidir.")
            }
        } else {
            lines.append("Altyazı okuma telefonun kendi yazı tanımasıyla yapılır; ücretsizdir ve internet gerektirmez.")
        }
        if translating {
            switch s.translator {
            case .google: lines.append("Google Çeviri: ücretsiz, anahtar gerekmez.")
            case .apple: lines.append("Apple Çeviri: internetsiz çalışır; önce dil paketini indir.")
            case .gemini, .openai, .claude: lines.append("Yapay zekâ çevirisi: en doğal sonuç; kendi API anahtarınla çalışır.")
            }
        } else {
            lines.append("“Sadece orijinal” gösterimde çeviri yapılmaz.")
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

    // MARK: Görünüm

    private var appearanceSection: some View {
        Section {
            Picker("Kutuda göster", selection: $s.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $s.lines, in: AppSettings.linesRange) {
                Text("Satır sayısı (kutu boyu): \(s.lines)")
            }
            VStack(alignment: .leading) {
                Text("Yazı boyutu: \(Int(s.fontSize))")
                Slider(value: $s.fontSize, in: 36...100, step: 2)
            }
            Picker("Hizalama", selection: $s.centered) {
                Text("Sola").tag(false)
                Text("Ortala").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("Yazı rengi", selection: $s.textColor) {
                ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Kutudaki ⏪ ⏩ ile satır sayısını değiştir", isOn: $s.pipButtonsResize)
        } header: {
            Text("Görünüm")
        } footer: {
            Text("iPhone, kutuyu iki parmakla yalnızca orantılı büyütür. Bu yüzden kutunun BOYUNU “Satır sayısı”, bir satıra sığan yazı miktarını (ENİNİ) “Yazı boyutu” belirler; genel büyüklüğü iki parmakla ayarlarsın. Değişiklikler kutuya anında yansır.")
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
        Section {
            Label("Kutuya dokununca çıkan ⏸ ile çeviriyi dondurabilirsin.", systemImage: "pause.circle")
            Label("Kutuyu ✕ ile kapatmak çeviriyi ve ekran yayınını durdurur.", systemImage: "xmark.circle")
            Label("Apple Music, Netflix gibi korumalı içerikleri iOS yakalatmaz.", systemImage: "lock")
            Label("Ayarlar değişince çeviri durmadan yeni ayara geçer.", systemImage: "gearshape")
        } header: {
            Text("İpuçları")
        } footer: {
            Text("Sürüm \(appVersion)")
        }
        .font(.footnote)
    }
}
