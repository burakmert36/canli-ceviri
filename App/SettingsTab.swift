import SwiftUI
import AVFoundation
import Translation

struct SettingsTab: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var power = PowerMonitor.shared
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var showAdvanced = false
    @State private var confirmClearHistory = false

    private var translating: Bool { s.displayMode != .original }
    private var usesGemini: Bool { s.asr == .gemini || s.translator == .gemini }
    private var usesOpenAI: Bool { s.asr == .openai || s.translator == .openai }

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                boxSection
                speechSection
                performanceSection
                enginesSection
                keysSection
                shortcutsSection
                historySection
                updatesSection
                advancedSection
                aboutSection
            }
            .navigationTitle("Ayarlar")
        }
        .translationTask(downloadConfig) { session in
            do { try await session.prepareTranslation() } catch {}
        }
        .onChange(of: s.asr) { _, _ in
            if s.inputSource == .audio && s.asr == .apple && s.sourceLang == "auto" { s.sourceLang = "en-US" }
        }
    }

    // MARK: Görünüm

    private var appearanceSection: some View {
        Section("Uygulama görünümü") {
            Picker("Tema", selection: $s.appTheme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 10) {
                Text("Vurgu rengi")
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { c in
                        Button {
                            s.accent = c
                        } label: {
                            Circle()
                                .fill(c.color)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.primary, lineWidth: s.accent == c ? 3 : 0).padding(-4))
                                .accessibilityLabel(c.title)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 4)
            }
            .padding(.vertical, 4)
        }
    }

    private var boxSection: some View {
        Section {
            if let img = engine.samplePreview() {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
            Picker("Kutuda göster", selection: $s.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $s.lines, in: AppSettings.linesRange) {
                Text("Satır sayısı: \(s.lines)")
            }
            .disabled(s.boxLocked)
            VStack(alignment: .leading) {
                Text("Yazı boyutu: \(Int(s.fontSize))")
                Slider(value: $s.fontSize, in: 36...100, step: 2)
            }
            .disabled(s.boxLocked)
            Picker("Hizalama", selection: $s.centered) {
                Text("Sola").tag(false)
                Text("Ortala").tag(true)
            }
            .pickerStyle(.segmented)
            Picker("Yazı rengi", selection: $s.textColor) {
                ForEach(SubtitleColor.allCases) { Text($0.title).tag($0) }
            }
            Picker("Arka plan", selection: $s.boxBackground) {
                ForEach(BoxBackground.allCases) { Text($0.title).tag($0) }
            }
            Picker("Yazı tipi", selection: $s.fontStyle) {
                ForEach(FontStyleChoice.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Kalın yazı", isOn: $s.boldText)
            Toggle(isOn: $s.boxLocked) {
                Label("Kutu boyutunu kilitle", systemImage: s.boxLocked ? "lock.fill" : "lock.open")
            }
            Picker("Kutudaki ⏪ ⏩", selection: $s.pipButtons) {
                ForEach(PiPButtonAction.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Altyazı kutusu")
        } footer: {
            Text("Yüzen kutunun yerini ve iki parmakla büyüklüğünü iOS yönetir: kutuyu ekranın altına ya da üstüne sürükle, iOS orada tutar ve bir dahaki sefere aynı yerde açar. Boyunu “Satır sayısı”, enini “Yazı boyutu” belirler.")
        }
    }

    // MARK: Seslendirme

    private var speechSection: some View {
        let lang = Languages.appleLanguageID(s.targetLang)
        let voices = Speaker.voices(for: lang)
        return Section {
            Toggle(isOn: $s.speakEnabled) {
                Label("Çeviriyi sesli oku", systemImage: "speaker.wave.2.fill")
            }
            if s.speakEnabled {
                Picker("Ne okunsun", selection: $s.speakTarget) {
                    ForEach(SpeakTarget.allCases) { Text($0.title).tag($0) }
                }
                Picker("Ses", selection: $s.voiceID) {
                    Text("Otomatik (en iyi ses)").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) · \(Speaker.qualityLabel(v))").tag(v.identifier)
                    }
                }
                VStack(alignment: .leading) {
                    Text("Okuma hızı")
                    Slider(value: $s.speechRate, in: 0.35...0.65)
                }
                Button {
                    engine.speaker.speak("Merhaba! Çeviriler bu sesle okunacak.", language: lang,
                                         voiceID: s.voiceID, rate: Float(s.speechRate))
                } label: {
                    Label("Sesi dene", systemImage: "play.circle")
                }
            }
        } header: {
            Text("Seslendirme")
        } footer: {
            Text("Ücretsizdir, cihazın kendi sesleri kullanılır. Daha doğal bir Türkçe ses için: Ayarlar > Erişilebilirlik > Seslendirilen İçerik > Sesler > Türkçe → “Gelişmiş” sesi indir. Ses modunda, okuma sırasında gelen konuşma kendi sesimizle karışmasın diye atlanır; kamera modunda kulaklık takılıysa hiçbir şey kaçmaz.")
        }
    }

    // MARK: Performans ve pil

    private var performanceSection: some View {
        Section {
            Picker("Pil tasarrufu", selection: $s.batteryMode) {
                ForEach(BatteryMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Konuşurken de çevir (canlı)", isOn: $s.liveTranslation)
            HStack {
                Label("Düşük Güç modu", systemImage: power.lowPowerMode ? "battery.25" : "battery.100")
                Spacer()
                Text(power.lowPowerMode ? "Açık" : "Kapalı").foregroundStyle(.secondary)
            }
            HStack {
                Label("Cihaz sıcaklığı", systemImage: "thermometer.medium")
                Spacer()
                Text(power.thermalTitle).foregroundStyle(power.isHot ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            }
            HStack {
                Label("Tasarruf şu an", systemImage: "leaf.fill")
                Spacer()
                Text(engine.saving ? "Etkin" : "Kapalı").foregroundStyle(engine.saving ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            }
        } header: {
            Text("Performans ve pil")
        } footer: {
            Text("Uygulama ekranda altyazı yokken okumayı seyrekleştirir, görüntü değişmiyorsa hiç okumaz ve aynı kutuyu tekrar çizmez. Tasarruf etkinken ayrıca: okuma daha seyrek ve hızlı modda yapılır, kamera 10 kare/sn'ye iner, yalnızca biten cümleler çevrilir. “Otomatik”, iPhone Düşük Güç modundayken ya da cihaz ısındığında devreye girer. “Konuşurken de çevir” kapalıysa çeviri cümle bitince gelir: daha az titreme, daha az internet ve pil.")
        }
    }

    // MARK: Diller ve motorlar

    private var enginesSection: some View {
        Section {
            Picker("Videonun dili", selection: $s.sourceLang) {
                ForEach(Languages.sources(for: s.asr == .apple && s.inputSource == .audio ? .apple : .gemini)) {
                    Text($0.name).tag($0.id)
                }
            }
            Picker("Çeviri dili", selection: $s.targetLang) {
                ForEach(Languages.targets) { Text($0.name).tag($0.id) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Ses tanıma").font(.subheadline)
                ASRPicker()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Çeviri motoru").font(.subheadline)
                TranslatorPicker()
            }
            if s.translator.isLLM {
                AIOptionsView()
            }
        } header: {
            Text("Diller ve motorlar")
        } footer: {
            Text("Ücretsiz olanlar: Apple ses tanıma, Google Çeviri, Apple Çeviri, Apple Zekâ ve altyazı okuma. Apple Zekâ cihazın kendi yapay zekâsıdır (internetsiz, bağlamı anlar); Ayarlar > Apple Intelligence ve Siri açık olmalı, desteklemediği durumda otomatik Google'a geçer. Gemini / ChatGPT / Claude kendi API anahtarınla çalışır.\(TranslationService.appleIntelligenceAvailable ? "" : "\n\nBu cihazda Apple Zekâ şu an hazır değil.")")
        }
    }

    private var keysSection: some View {
        Section {
            SecureField("Gemini API anahtarı", text: $s.geminiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Link("Ücretsiz Gemini anahtarı al → aistudio.google.com",
                 destination: URL(string: "https://aistudio.google.com/apikey")!).font(.footnote)
            SecureField("OpenAI API anahtarı", text: $s.openaiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Link("OpenAI anahtarı al → platform.openai.com",
                 destination: URL(string: "https://platform.openai.com/api-keys")!).font(.footnote)
            SecureField("Claude API anahtarı", text: $s.claudeKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Link("Claude anahtarı al → console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.footnote)
        } header: {
            Text("API anahtarları (isteğe bağlı)")
        } footer: {
            Text("Anahtarlar yalnızca bu cihazda saklanır ve sadece ilgili şirkete gönderilir.")
        }
    }

    // MARK: Kısayollar

    private var shortcutsSection: some View {
        Section {
            Label("Hazır kısayollar: Ekranı Çevir, Kamera Çevirisi, Dili Değiştir, Duraklat / Sürdür, Çeviriyi Durdur.", systemImage: "bolt.fill")
            Label("iPhone Eylem Düğmesi: Ayarlar → Eylem Düğmesi → Kestirme → Canlı Çeviri → “Ekranı Çevir” ya da çeviri açıkken dil değiştirmek için “Dili Değiştir”", systemImage: "button.programmable")
            Label("Siri: “Canlı Çeviri ile ekranı çevir”", systemImage: "mic.fill")
            VStack(alignment: .leading, spacing: 6) {
                Label("Arkaya iki kez dokun → ekrandaki yazıyı çevir", systemImage: "hand.tap.fill")
                    .font(.subheadline.weight(.semibold))
                Text("1) Kestirmeler → + → “Ekran Görüntüsü Al” ekle → “Görüntüdeki Yazıyı Çevir” (Canlı Çeviri) ekle → “Sonucu Göster” ekle.\n2) Ayarlar → Erişilebilirlik → Dokunma → Arkaya Dokunma → İki Kez Dokunma → bu kestirmeyi seç.\nArtık oyun menüsü, manga, mesaj… ne görürsen telefonun arkasına iki kez dokununca Türkçesi çıkar. Ücretsiz ve yayın gerektirmez.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let url = URL(string: "shortcuts://") {
                Link(destination: url) { Label("Kestirmeler uygulamasını aç", systemImage: "square.stack.3d.up") }
            }
        } header: {
            Text("Kısayollar")
        }
        .font(.subheadline)
    }

    // MARK: Geçmiş

    private var historySection: some View {
        Section {
            Toggle("Çevirileri geçmişe kaydet", isOn: $s.historyEnabled)
            HStack {
                Text("Kayıtlı cümle")
                Spacer()
                Text("\(history.entries.count)").foregroundStyle(.secondary)
            }
            if !history.entries.isEmpty {
                Button("Geçmişi temizle", role: .destructive) { confirmClearHistory = true }
            }
        } header: {
            Text("Geçmiş")
        }
        .confirmationDialog("Tüm geçmiş silinsin mi?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Hepsini sil", role: .destructive) { history.clear() }
            Button("Vazgeç", role: .cancel) {}
        }
    }

    // MARK: Güncellemeler

    private var updatesSection: some View {
        Section {
            HStack {
                Text("Yüklü sürüm")
                Spacer()
                Text(updates.currentVersion).foregroundStyle(.secondary)
            }
            HStack {
                Text("En son sürüm")
                Spacer()
                if updates.checking {
                    ProgressView()
                } else {
                    Text(updates.latestVersion ?? "—").foregroundStyle(updates.updateAvailable ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
            }
            if updates.updateAvailable {
                Label("Güncellemek için: SideStore → My Apps → Canlı Çeviri → Update", systemImage: "arrow.down.circle")
                    .font(.footnote)
            }
            if let e = updates.lastError {
                Text(e).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Şimdi denetle") { updates.check() }
            Link(destination: UpdateChecker.releasesURL) {
                Label("Tüm sürümler (Versiyon 1'e dönüş dahil)", systemImage: "clock.arrow.circlepath")
            }
        } header: {
            Text("Güncellemeler")
        } footer: {
            Text("Bir sürümde sorun olursa, oradan önceki sürümün CanliCeviri.ipa dosyasını indirip SideStore ile yükleyerek geri dönebilirsin.")
        }
    }

    // MARK: Gelişmiş ve hakkında

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

    private var aboutSection: some View {
        Section {
            Button {
                s.onboardingDone = false
            } label: {
                Label("Tanıtımı tekrar göster", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Yardım")
        } footer: {
            Text("Canlı Çeviri \(updates.currentVersion) · Kişisel kullanım için. Ses ve görüntü cihaz dışına yalnızca seçtiğin bulut motoruna gönderilir.")
        }
    }
}
