import SwiftUI

/// Telefonun kendi ekranındaki videoları çeviren mod (ekran yayını + yüzen kutu).
struct ScreenTab: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var router = AppRouter.shared
    @State private var showAreaPicker = false

    private var translating: Bool { s.displayMode != .original }
    private var boxAspect: CGFloat {
        OverlayRenderer.aspect(mode: s.displayMode, lines: s.lines, fontSize: CGFloat(s.fontSize),
                               style: s.fontStyle, bold: s.boldText)
    }
    private var cameraRunning: Bool { engine.running && engine.runMode == .camera }

    var body: some View {
        NavigationStack {
            Form {
                if updates.updateAvailable { updateSection }
                controlSection
                sourceSection
                if translating { engineSection }
                if s.inputSource == .screen { captionAreaSection }
                boxSection
                Section("Hızlı profil") {
                    PresetStrip()
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
                tipsSection
            }
            .navigationTitle("Ekran Çevirisi")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showAreaPicker) {
                AreaPickerView().environmentObject(engine).environmentObject(s)
            }
        }
    }

    private var engineSection: some View {
        Section {
            TranslatorPicker()
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            if s.translator.isLLM {
                AIOptionsView()
            }
        } header: {
            Text("Çeviri motoru")
        } footer: {
            Text("Ücretsiz: Google, iPhone Çeviri, Apple Zekâ. Gemini / ChatGPT / Claude daha doğal çevirir; kendi anahtarınla çalışır. Seçili motorun modelini “Ayarla”dan değiştirebilirsin. İnternet giderse uygulama kendiliğinden iPhone Çeviri'ye geçer (dil paketi indirilmişse); aynı cümle tekrar gelirse yeniden çevirmez.")
        }
    }

    // MARK: Bölümler

    private var updateSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yeni sürüm hazır: \(updates.latestVersion ?? "")").font(.subheadline.weight(.semibold))
                    Text("SideStore → My Apps → Canlı Çeviri → Update").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controlSection: some View {
        Section {
            OverlayPreview(layer: engine.pip.displayLayer)
                .aspectRatio(boxAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))

            if cameraRunning {
                Label("Kamera çevirisi açık. Ekran çevirisi için önce onu durdur.", systemImage: "camera.viewfinder")
                    .font(.footnote)
                Button("Kamera çevirisini durdur", role: .destructive) { engine.stop() }
            } else {
                PrimaryButton(running: engine.running, startTitle: "Başlat") { engine.toggle(.screen) }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            HStack {
                StatusRow(connected: engine.audioConnected && engine.runMode == .screen,
                          running: engine.running, text: engine.status)
                Spacer(minLength: 4)
                BroadcastButton().frame(width: 40, height: 40)
            }

            if engine.running && engine.runMode == .screen {
                HStack(spacing: 10) {
                    Button {
                        engine.togglePause()
                    } label: {
                        Label(engine.paused ? "Devam" : "Duraklat", systemImage: engine.paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        engine.clearCaptions()
                    } label: {
                        Label("Temizle", systemImage: "eraser").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    if !engine.boxVisible {
                        Button {
                            engine.showBox()
                        } label: {
                            Label("Kutu", systemImage: "pip.enter").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            Text("Başlat → açılan pencerede “Yayını Başlat” → videoya geç. Sağdaki ⏺ ekran yayınını elle açar.")
        }
    }

    private var sourceSection: some View {
        Section {
            Picker("Kaynak", selection: $s.inputSource) {
                Text("Altyazıyı oku").tag(InputSource.screen)
                Text("Sesi dinle").tag(InputSource.audio)
            }
            .pickerStyle(.segmented)

            if s.inputSource == .audio {
                ASRPicker()
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
                QuickPairStrip(input: s.inputSource)
                if let sw = Languages.swapped(source: s.sourceLang, target: s.targetLang) {
                    Button {
                        s.sourceLang = sw.source
                        s.targetLang = sw.target
                    } label: {
                        Label("Dilleri yer değiştir", systemImage: "arrow.left.arrow.right")
                    }
                }
            }
        } header: {
            Text("Kaynak ve dil")
        } footer: {
            Text(s.inputSource == .screen
                 ? "Videodaki altyazıyı (YouTube'da CC) okuyup çevirir. Konuşmacılar karışmaz; en doğru sonuç budur. Videoda altyazıyı açmayı unutma."
                 : "Konuşmayı dinleyip yazıya döker; altyazısı olmayan videolar ve şarkılar için.")
        }
    }

    private var captionAreaSection: some View {
        Section {
            Picker("Alan", selection: $s.ocrAreaMode) {
                ForEach(OCRAreaMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if s.ocrAreaMode == .manual {
                Button {
                    showAreaPicker = true
                } label: {
                    HStack(spacing: 12) {
                        AreaThumb(rect: s.portraitArea, landscape: false)
                        AreaThumb(rect: s.landscapeArea, landscape: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Altyazı alanını seç").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text("Dikey ve yatay video için ayrı").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text("Altyazı alanı")
        } footer: {
            Text(s.ocrAreaMode == .manual
                 ? "Uygulama, video o an dikey mi yatay mı oynuyor kendisi anlar ve senin o yön için seçtiğin alanı okur. En iyi sonuç için: Başlat → YouTube'da altyazılı videoyu aç → 2–3 sn sonra buraya dön → “Altyazı alanını seç”: gerçek ekran görüntüsü üstünde 4 köşeden ayarlarsın."
                 : "Otomatik mod videonun oynadığı bölgeyi kendisi bulmaya çalışır; her videoda doğru çalışmayabilir. Sorun olursa “Seçtiğim alan”a geç.")
        }
    }

    private var boxSection: some View {
        Section {
            Picker("Kutuda göster", selection: $s.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
            }
            Stepper(value: $s.lines, in: AppSettings.linesRange) {
                Text("Satır sayısı (kutu boyu): \(s.lines)")
            }
            .disabled(s.boxLocked)
            Toggle(isOn: $s.boxLocked) {
                Label("Kutu boyutunu kilitle", systemImage: s.boxLocked ? "lock.fill" : "lock.open")
            }
            Picker("Kutudaki ⏪ ⏩", selection: $s.pipButtons) {
                ForEach(PiPButtonAction.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Kutu")
        } footer: {
            Text("Kutunun boyunu “Satır sayısı” belirler (yazı boyutu, renk ve tema: Ayarlar). Genel büyüklüğü iki parmakla ayarla, ekranın altına ya da üstüne sürükle: iOS orada tutar ve sonraki açılışta aynı yerde açar. Kilit, boyutun yanlışlıkla değişmesini engeller. “Kutudaki ⏪ ⏩ → Dil değiştir” seçilirse kutuya dokunup ⏩ ile son kullandığın dil çiftleri arasında geçersin.")
        }
    }

    private var tipsSection: some View {
        Section {
            Label("Kutuya dokununca çıkan ⏸ ile çeviriyi dondurabilirsin.", systemImage: "pause.circle")
            Label("Kutuyu ✕ ile kapatmak çeviriyi ve ekran yayınını durdurur.", systemImage: "xmark.circle")
            Label("Kutuyu kenara itersen gizlenir; kenardaki oka dokununca geri gelir.", systemImage: "arrow.left.to.line")
        } header: {
            Text("İpuçları")
        }
        .font(.footnote)
    }
}
