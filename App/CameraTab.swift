import SwiftUI
import AVFoundation

/// Kamera / TV modu: cihazı TV'ye (ör. GTA 6) tutup altyazıyı okur ya da konuşmayı dinler; çeviriyi gösterir ve seslendirir.
struct CameraTab: View {
    @EnvironmentObject private var engine: Engine
    @EnvironmentObject private var s: AppSettings
    @ObservedObject private var camera = Engine.shared.camera
    @ObservedObject private var router = AppRouter.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var cameraDenied = false

    private var screenRunning: Bool { engine.running && engine.runMode == .screen }
    private var cameraRunning: Bool { engine.running && engine.runMode == .camera }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let landscape = geo.size.width > geo.size.height * 1.05
                Group {
                    if landscape {
                        HStack(alignment: .top, spacing: 14) {
                            viewer.frame(maxWidth: .infinity, maxHeight: .infinity)
                            ScrollView { panel }
                                .frame(width: min(420, geo.size.width * 0.42))
                        }
                    } else {
                        VStack(spacing: 12) {
                            viewer.frame(maxHeight: geo.size.height * (s.camInput == .screen ? 0.5 : 0.28))
                            ScrollView { panel }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            .navigationTitle("Kamera / TV")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { updateCamera() }
        .onChange(of: router.tab) { _, _ in updateCamera() }
        .onChange(of: s.camInput) { _, _ in updateCamera() }
        .onChange(of: s.camZoom) { _, z in camera.setZoom(CGFloat(z)) }
    }

    /// Sekme görünürken ve kamera kaynağı seçiliyken önizlemeyi aç; değilse kapat.
    private func updateCamera() {
        let wantsPreview = router.tab == .camera && s.camInput == .screen
        if wantsPreview {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                cameraDenied = false
                camera.start()
                camera.setZoom(CGFloat(s.camZoom))
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    DispatchQueue.main.async {
                        cameraDenied = !ok
                        if ok { camera.start(); camera.setZoom(CGFloat(s.camZoom)) }
                    }
                }
            default:
                cameraDenied = true
            }
        } else if !cameraRunning || s.camInput != .screen {
            camera.stop()
        }
    }

    // MARK: Görüntü alanı

    @ViewBuilder
    private var viewer: some View {
        if s.camInput == .screen {
            if cameraDenied {
                messageCard(icon: "camera.fill", title: "Kamera izni gerekli",
                            text: "Altyazıyı okuyabilmem için kameraya izin ver.",
                            button: "Ayarları aç") { openSettings() }
            } else if camera.unavailable {
                messageCard(icon: "camera.badge.ellipsis", title: "Kamera bulunamadı",
                            text: "Bu cihazda arka kamera kullanılamıyor.", button: nil) {}
            } else {
                ZStack {
                    CameraPreview(capture: camera)
                    AreaEditor(rect: Binding(get: { s.cameraRect }, set: { s.cameraRect = $0 }))
                }
                .aspectRatio(camera.isPortraitImage ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: cameraRunning ? "waveform" : "mic.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: cameraRunning && !engine.paused)
                Text(cameraRunning ? "TV'nin sesini dinliyorum" : "Mikrofonla dinleme")
                    .font(.headline)
                Text("Cihazı TV'ye yakın tut. Seslendirme açıkken kulaklık takarsan konuşmalar hiç kaçmaz.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
    }

    // MARK: Altyazı ve kontroller

    private var mainText: String { s.displayMode == .original ? engine.shownOriginal : engine.shownTranslation }
    private var subtitleSize: CGFloat { CGFloat(s.fontSize) * (sizeClass == .regular ? 0.6 : 0.42) }

    private var panel: some View {
        VStack(spacing: 12) {
            subtitleCard
            controls
        }
        .padding(.bottom, 12)
    }

    private var subtitleCard: some View {
        VStack(alignment: s.centered ? .center : .leading, spacing: 6) {
            if s.displayMode == .both && !engine.shownOriginal.isEmpty {
                Text(engine.shownOriginal)
                    .font(.system(size: subtitleSize * 0.62, design: s.fontStyle.swiftUIDesign))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            Text(mainText.isEmpty ? placeholder : mainText)
                .font(.system(size: subtitleSize, weight: s.boldText ? .semibold : .regular, design: s.fontStyle.swiftUIDesign))
                .foregroundStyle(mainText.isEmpty ? Color.white.opacity(0.5) : Color(s.textColor.uiColor))
                .lineLimit(max(2, s.lines))
                .truncationMode(.head)
        }
        .multilineTextAlignment(s.centered ? .center : .leading)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: s.centered ? .bottom : .bottomLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(s.boxBackground.uiColor)))
        .textSelection(.enabled)
    }

    private var placeholder: String {
        if !cameraRunning { return "Başlat'a dokun" }
        if engine.paused { return "Duraklatıldı" }
        return s.camInput == .screen ? "Altyazı bekleniyor…" : "Konuşma bekleniyor…"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Kaynak", selection: $s.camInput) {
                Text("Altyazıyı oku").tag(InputSource.screen)
                Text("Konuşmayı dinle").tag(InputSource.audio)
            }
            .pickerStyle(.segmented)
            .disabled(cameraRunning)

            if s.camInput == .audio {
                ASRPicker()
            }

            LanguageBar(sourceOptions: Languages.sources(for: s.camInput == .audio ? s.asr : .gemini),
                        showTarget: s.displayMode != .original)

            if s.displayMode != .original {
                QuickPairStrip(input: s.camInput)
                TranslatorPicker()
                if s.translator.isLLM { AIOptionsView() }
            }

            HStack(spacing: 10) {
                Toggle(isOn: $s.speakEnabled) {
                    Label("Sesli oku", systemImage: s.speakEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)

                if s.camInput == .screen && camera.maxZoom > 1 {
                    HStack(spacing: 6) {
                        Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                        Slider(value: $s.camZoom, in: 1...Double(camera.maxZoom))
                        Text(String(format: "%.1fx", s.camZoom)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }

            if screenRunning {
                Label("Ekran çevirisi açık. Kamera için önce onu durdur.", systemImage: "pip")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Ekran çevirisini durdur", role: .destructive) { engine.stop() }
                    .buttonStyle(.bordered)
            } else {
                HStack(spacing: 10) {
                    PrimaryButton(running: cameraRunning, startTitle: "Başlat") { engine.toggle(.camera) }
                    if cameraRunning {
                        Button {
                            engine.togglePause()
                        } label: {
                            Image(systemName: engine.paused ? "play.fill" : "pause.fill")
                                .font(.headline).frame(width: 44, height: 36)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        Button {
                            engine.clearCaptions()
                        } label: {
                            Image(systemName: "eraser").font(.headline).frame(width: 44, height: 36)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
            }

            StatusRow(connected: cameraRunning, running: cameraRunning, text: engine.status)

            if s.camInput == .screen {
                Text("Sarı çerçeveyi içinden sürükle, 4 köşesinden boyutlandır; yalnızca altyazının çıktığı yeri kapsasın. Yansımayı azaltmak için cihazı TV'ye dik tut; yakınlaştırma ile altyazıyı büyüt.\(camera.hasCameraControl ? " Kamera Denetimi düğmesinde parmağını kaydırarak da yakınlaştırabilirsin." : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func messageCard(icon: String, title: String, text: String, button: String?, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let b = button { Button(b, action: action).buttonStyle(.borderedProminent) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemBackground)))
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
