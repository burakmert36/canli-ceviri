import SwiftUI

/// Telefonun kendi ekranındaki videoları çeviren mod (ekran yayını + yüzen kutu).
struct ScreenTab: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var updates = UpdateChecker.shared
    @ObservedObject private var router = AppRouter.shared

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

            Picker("Videonun dili", selection: $s.sourceLang) {
                ForEach(Languages.sources(for: s.inputSource == .audio ? s.asr : .gemini)) {
                    Text($0.name).tag($0.id)
                }
            }
            if translating {
                Picker("Çeviri dili", selection: $s.targetLang) {
                    ForEach(Languages.targets) { Text($0.name).tag($0.id) }
                }
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
            Toggle("Altyazının yerini otomatik bul", isOn: $s.ocrAuto)
            if let img = engine.ocrPreview {
                previewImage(img)
                if !engine.ocrPreviewText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bu alanda okunan:").font(.caption).foregroundStyle(.secondary)
                        Text(engine.ocrPreviewText).font(.footnote)
                    }
                }
            }
            if !s.ocrAuto {
                VStack(alignment: .leading) {
                    Text("Üst sınır: %\(Int(s.ocrTop * 100))")
                    Slider(value: Binding(get: { s.ocrTop }, set: { s.ocrTop = min($0, s.ocrBottom - 0.05) }), in: 0...0.95)
                }
                VStack(alignment: .leading) {
                    Text("Alt sınır: %\(Int(s.ocrBottom * 100))")
                    Slider(value: Binding(get: { s.ocrBottom }, set: { s.ocrBottom = max($0, s.ocrTop + 0.05) }), in: 0.05...1)
                }
            }
        } header: {
            Text("Altyazı yeri")
        } footer: {
            Text(s.ocrAuto
                 ? "Uygulama videonun oynadığı bölgeyi kendisi bulur: dikeyde üstteki oynatıcıyı, yatayda tüm ekranı. Başlık, beğeni, yorum ve süre gibi yazılar okunmaz. Kontrol etmek için: videoyu izlerken uygulamaya dön; sarı çerçeve bulunan alanı gösterir."
                 : "Elle modda sarı şerit altyazının çıktığı yatay bölgeyi kapsamalı. Dikey ve yatay izleme için farklı ayar gerekebilir; otomatik mod önerilir.")
        }
    }

    private func previewImage(_ img: UIImage) -> some View {
        ZStack {
            Image(uiImage: img).resizable().scaledToFit()
            if let area = engine.ocrPreviewArea {
                GeometryReader { geo in
                    let W = geo.size.width, H = geo.size.height
                    let r = CGRect(x: area.minX * W, y: area.minY * H, width: area.width * W, height: area.height * H)
                    ZStack(alignment: .topLeading) {
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: geo.size))
                            p.addRect(r)
                        }
                        .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.yellow, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
            }
        }
        .aspectRatio(img.size, contentMode: .fit)
        .frame(maxHeight: 360)
        .frame(maxWidth: .infinity)
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
            VStack(alignment: .leading) {
                Text("Yazı boyutu (satıra sığan yazı): \(Int(s.fontSize))")
                Slider(value: $s.fontSize, in: 36...100, step: 2)
            }
            .disabled(s.boxLocked)
            Toggle(isOn: $s.boxLocked) {
                Label("Kutu boyutunu kilitle", systemImage: s.boxLocked ? "lock.fill" : "lock.open")
            }
        } header: {
            Text("Kutu")
        } footer: {
            Text("Kutunun boyunu “Satır sayısı”, enini “Yazı boyutu” belirler; genel büyüklüğü kutuyu iki parmakla açıp kapatarak ayarlarsın. Kutuyu ekranın altına ya da üstüne sürüklersen iOS onu orada tutar ve bir sonraki açılışta aynı yerde ve boyutta açar. Kilit, boyut ayarlarının ve kutudaki ⏪ ⏩ düğmelerinin yanlışlıkla değişmesini engeller.")
        }
    }

    private var tipsSection: some View {
        Section {
            Label("Kutuya dokununca çıkan ⏸ ile çeviriyi dondurabilirsin.", systemImage: "pause.circle")
            Label("Kutuyu ✕ ile kapatmak çeviriyi ve ekran yayınını durdurur.", systemImage: "xmark.circle")
            Label("Kutuyu ekranın kenarına doğru itersen gizlenir; kenardaki oka dokununca geri gelir.", systemImage: "arrow.left.to.line")
            Label("Apple Music, Netflix gibi korumalı içerikleri iOS yakalatmaz.", systemImage: "lock")
        } header: {
            Text("İpuçları")
        }
        .font(.footnote)
    }
}
