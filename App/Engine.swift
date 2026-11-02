import Foundation
import UIKit
import Combine
import AVFoundation

struct Segment {
    var id: Int
    var original: String = ""
    var translation: String = ""
    var translatedSource: String = ""
}

/// Ses/ekran/kamera → yazı → çeviri → kutu (+ seslendirme, geçmiş) akışını yöneten ana sınıf.
/// Tüm durum ana iş parçacığında tutulur.
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var running = false
    @Published private(set) var runMode: RunMode = .screen
    /// Kaynak bağlı mı (ekran modunda yayın, kamera modunda kamera/mikrofon)?
    @Published private(set) var audioConnected = false
    @Published private(set) var status = "Hazır"
    @Published private(set) var paused = false
    @Published private(set) var boxVisible = false
    /// Altyazı alanı seçicisi için son alınan dikey / yatay ekran görüntüsü var mı?
    @Published private(set) var hasPortraitShot = false
    @Published private(set) var hasLandscapeShot = false
    /// Uygulama içinde gösterilen (kamera modu) son metinler.
    @Published private(set) var shownOriginal = ""
    @Published private(set) var shownTranslation = ""

    let settings = AppSettings.shared
    let pip = PiPManager()
    let camera = CameraCapture()
    let speaker = Speaker()

    private let renderer = OverlayRenderer()
    private let receiver = AudioReceiver()
    private let keepAlive = KeepAlive()
    private let mic = MicCapture()
    private let reader = ScreenTextReader()
    private let captions = CaptionTracker()
    private let history = HistoryStore.shared
    private var cfg: EngineConfig
    private var service: TranslationService
    private var apple: AppleRecognizer?
    private var chunker: Chunker?
    private var screenMode = false   // metin kaynağı: görüntüdeki yazı (ekran ya da kamera)
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var broadcastConnected = false

    // Altyazı durumu
    private var committed: [Segment] = []
    private var live = Segment(id: 0)
    private var liveWords: [String] = []
    private var localSegment = 2_000_000
    private var lastChange = Date()
    private var segStart = Date()
    private var lastAudioAt = Date.distantPast
    private var recognizerErrors = 0

    // Seslendirme ve geçmiş
    private var spoken = Set<Int>()
    private var historyIDs: [Int: UUID] = [:]

    // Pil ve performans: uyarlanabilir okuma sıklığı
    private let power = PowerMonitor.shared
    private var lastCaptionAt = Date.distantPast
    private var lastOCRSubmit = Date.distantPast
    private var videoMode: AudioReceiver.VideoMode = .off
    private var lastToggle = Date.distantPast

    // Stabilite: çeviri hatalarında artan bekleme
    private var translateFailures = 0
    private var backoffUntil = Date.distantPast
    private var pendingRetry = Set<Int>()

    // Uygulama durumu (ekran okuma yalnızca başka uygulamadayken yapılır)
    private var appInBackground = false
    private var lastPortraitFrame: ScreenFrame?
    private var lastLandscapeFrame: ScreenFrame?

    // Çeviri istekleri (segment başına en fazla 1 eşzamanlı istek)
    private var inFlight = Set<Int>()
    private var dirty = Set<Int>()
    private var debounce: DispatchWorkItem?

    // Bulut modu sıralaması
    private var nextSeq = 0
    private var applySeq = 0
    private var cloudPending: [Int: Date] = [:]
    private var cloudDone: [Int: (String, String)] = [:]
    private var cloudInFlight = 0

    // Çizim
    private var renderScheduled = false
    private var lastRender = Date.distantPast
    private var lastRenderKey = ""
    private var styleVersion = 0

    private init() {
        cfg = EngineConfig(AppSettings.shared)
        service = TranslationService(config: cfg)

        pip.onUserClosed = { [weak self] in
            guard let self = self, self.runMode == .screen else { return }
            self.stop()
        }
        pip.onPauseToggled = { [weak self] p in self?.setPaused(p) }
        pip.onStatus = { [weak self] s in self?.status = s }
        pip.onActiveChanged = { [weak self] active in self?.boxVisible = active }
        pip.onSkip = { [weak self] forward in
            guard let self = self, self.settings.pipButtonsResize else { return }
            self.settings.changeLines(by: forward ? 1 : -1)
            self.renderNow()
        }
        pip.showsSkipButtons = settings.pipButtonsResize && !settings.boxLocked

        receiver.onAudio = { [weak self] samples in
            DispatchQueue.main.async {
                guard let self = self, self.runMode == .screen else { return }
                self.handleAudio(samples)
            }
        }
        receiver.onFrame = { [weak self] frame in
            self?.handleBroadcastFrame(frame)
        }
        receiver.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.connectionChanged(connected) }
        }
        receiver.ensureListening()

        camera.onFrame = { [weak self] frame in
            DispatchQueue.main.async { self?.handleCameraFrame(frame) }
        }
        mic.onSamples = { [weak self] samples in
            DispatchQueue.main.async {
                guard let self = self, self.runMode == .camera else { return }
                self.handleAudio(samples)
            }
        }

        reader.onResult = { [weak self] lines, frame in self?.handleOCR(lines, frame: frame) }
        configureReader()

        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.receiver.ensureListening()
            self?.renderNow()
        }
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.appInBackground = true
            self?.captions.resetBaseline()
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.appInBackground = false
            self.hasPortraitShot = self.lastPortraitFrame != nil
            self.hasLandscapeShot = self.lastLandscapeFrame != nil
        }
        nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMemoryWarning()
        }
        power.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.powerChanged() }
            .store(in: &cancellables)
        appInBackground = UIApplication.shared.applicationState == .background

        DispatchQueue.main.async { [weak self] in self?.renderNow() }
    }

    // MARK: - Başlat / Durdur (ekran modu)

    func start() {
        guard !running else { return }
        let c = EngineConfig(settings, mode: .screen)
        if let problem = validate(c) { status = problem; return }
        if c.usesAppleASR {
            status = "İzin isteniyor…"
            AppleRecognizer.requestAuthorization { [weak self] ok in
                guard let self = self else { return }
                if ok { self.begin(c) } else {
                    self.status = "Konuşma tanıma izni gerekli: Ayarlar > Uygulamalar > Canlı Çeviri"
                }
            }
        } else {
            begin(c)
        }
    }

    private func validate(_ c: EngineConfig) -> String? {
        if c.usesAppleASR && c.sourceIsAuto { return "Apple ses tanıma için videonun dilini seçmelisin." }
        if c.translationEnabled {
            if c.translator == .apple && c.sourceIsAuto { return "Apple Çeviri için videonun dilini seçmelisin." }
            if c.translator == .apple, #unavailable(iOS 26.0) { return "Apple Çeviri için iOS 26 gerekli." }
        }
        let needsGemini = (c.usesCloudASR && c.asr == .gemini) || (c.translationEnabled && c.translator == .gemini)
        let needsOpenAI = (c.usesCloudASR && c.asr == .openai) || (c.translationEnabled && c.translator == .openai)
        let needsClaude = c.translationEnabled && c.translator == .claude
        if needsGemini && c.geminiKey.isEmpty { return "Gemini API anahtarını gir (Ayarlar)." }
        if needsOpenAI && c.openaiKey.isEmpty { return "OpenAI API anahtarını gir (Ayarlar)." }
        if needsClaude && c.claudeKey.isEmpty { return "Claude API anahtarını gir (Ayarlar)." }
        return nil
    }

    private func begin(_ c: EngineConfig) {
        do {
            try keepAlive.start()
        } catch {
            status = "Ses oturumu açılamadı: \(error.localizedDescription)"
            return
        }
        runMode = .screen
        receiver.ensureListening()
        cfg = c
        service = TranslationService(config: c)
        resetCaptions()
        guard startRecognition() else { keepAlive.stop(); return }

        running = true
        paused = false
        pip.paused = false
        pip.autoStartWhenBackgrounded = true
        pip.showsSkipButtons = settings.pipButtonsResize && !settings.boxLocked
        audioConnected = broadcastConnected
        status = broadcastConnected ? connectedStatus : "Ekran yayını bekleniyor…"
        startTimer()
        renderNow()
        pip.start()

        // Ekran yayını açık değilse sistem penceresini aç.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.running, self.runMode == .screen, !self.broadcastConnected else { return }
            BroadcastPicker.present()
        }
    }

    // MARK: - Başlat (kamera / TV modu)

    func startCamera() {
        guard !running else { return }
        let c = EngineConfig(settings, mode: .camera)
        if let problem = validate(c) { status = problem; return }
        status = "İzinler kontrol ediliyor…"
        Permissions.request(camera: c.input == .screen, microphone: c.input == .audio, speech: c.usesAppleASR) { [weak self] ok, message in
            guard let self = self else { return }
            if ok { self.beginCamera(c) } else { self.status = message }
        }
    }

    private func beginCamera(_ c: EngineConfig) {
        do {
            let session = AVAudioSession.sharedInstance()
            if c.input == .audio {
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            status = "Ses oturumu açılamadı: \(error.localizedDescription)"
            return
        }
        runMode = .camera
        cfg = c
        service = TranslationService(config: c)
        resetCaptions()
        guard startRecognition() else { return }
        if c.input == .audio {
            do {
                try mic.start()
            } catch {
                status = "Mikrofon açılamadı: \(error.localizedDescription)"
                stopRecognition()
                return
            }
        } else {
            camera.start()
            camera.setZoom(CGFloat(settings.camZoom))
            camera.setFrameRate(saving ? 10 : 15)
        }
        running = true
        paused = false
        audioConnected = true
        status = c.input == .audio ? "Mikrofon dinleniyor" : "Kamera altyazıyı okuyor"
        UIApplication.shared.isIdleTimerDisabled = true
        startTimer()
        renderNow()
    }

    // MARK: - Durdur

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        speaker.stop()
        stopRecognition()
        if runMode == .camera {
            mic.stop()
            UIApplication.shared.isIdleTimerDisabled = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioConnected = broadcastConnected
            runMode = .screen
        } else {
            setVideoMode(.off)
            receiver.requestBroadcastStop()
            pip.autoStartWhenBackgrounded = false
            pip.stop()
            keepAlive.stop()
        }
        status = "Durduruldu"
        renderNow()
    }

    func toggle(_ mode: RunMode) {
        // Art arda hızlı dokunuşlarda başlat/durdur sıçramasını önle.
        guard Date().timeIntervalSince(lastToggle) > 0.8 else { return }
        lastToggle = Date()
        if running {
            stop()
        } else if mode == .camera {
            startCamera()
        } else {
            start()
        }
    }

    func openBroadcastPicker() { BroadcastPicker.present() }

    func showBox() {
        guard running, runMode == .screen else { return }
        renderNow()
        pip.start()
    }

    func togglePause() { setPaused(!paused) }

    /// Kutudaki ve geçmişteki son metinleri temizler.
    func clearCaptions() {
        committed.removeAll()
        live.original = ""
        live.translation = ""
        live.translatedSource = ""
        liveWords = []
        renderNow()
    }

    private var connectedStatus: String {
        if runMode == .camera { return cfg.input == .audio ? "Mikrofon dinleniyor" : "Kamera altyazıyı okuyor" }
        return screenMode ? "Ekrandaki altyazı okunuyor" : "Ses alınıyor"
    }

    private func setPaused(_ p: Bool) {
        paused = p
        pip.paused = p
        pip.refreshControls()
        if p { debounce?.cancel(); speaker.stop() }
        status = p ? "Duraklatıldı" : (audioConnected ? connectedStatus : status)
        renderNow()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: - Tanıma

    private func configureReader() {
        let lang = running ? cfg.sourceLang : settings.sourceLang
        if runMode == .camera {
            let r = settings.cameraRect
            reader.configure(portrait: r, landscape: r, auto: false, sourceLang: lang, fast: saving)
        } else {
            // Video dikey ya da yatay oynarken her biri için kullanıcının seçtiği ayrı alan kullanılır.
            reader.configure(portrait: settings.portraitArea, landscape: settings.landscapeArea,
                             auto: settings.ocrAreaMode == .auto, sourceLang: lang, fast: saving)
        }
    }

    private func startRecognition() -> Bool {
        stopRecognition()
        live = Segment(id: nextLocalSegment())
        liveWords = []
        if cfg.input == .screen {
            screenMode = true
            captions.resetAll()
            reader.resetDetection()
            configureReader()
            lastCaptionAt = Date()
            if runMode == .screen { setVideoMode(.fast) }
            return true
        }
        screenMode = false
        if runMode == .screen { setVideoMode(.off) }
        if cfg.asr == .apple {
            guard let r = AppleRecognizer(localeID: cfg.sourceLang) else {
                status = "Bu dil için Apple ses tanıma yok. Bulut tanımayı dene."
                return false
            }
            r.onPartial = { [weak self] seg, text in self?.applePartial(seg, text) }
            r.onFinal = { [weak self] seg, text in self?.appleFinal(seg, text) }
            apple = r
            r.startSegment()
            live = Segment(id: r.segment)
            recognizerErrors = 0
        } else {
            chunker = Chunker()
        }
        return true
    }

    private func stopRecognition() {
        apple?.stop()
        apple = nil
        chunker = nil
        screenMode = false
    }

    private func nextLocalSegment() -> Int {
        localSegment += 1
        return localSegment
    }

    private func resetCaptions() {
        committed.removeAll()
        live = Segment(id: 0)
        liveWords = []
        inFlight.removeAll()
        dirty.removeAll()
        spoken.removeAll()
        historyIDs.removeAll()
        pendingRetry.removeAll()
        translateFailures = 0
        backoffUntil = .distantPast
        nextSeq = 0
        applySeq = 0
        cloudPending.removeAll()
        cloudDone.removeAll()
        cloudInFlight = 0
    }

    private func settingsChanged() {
        styleVersion += 1
        pip.showsSkipButtons = settings.pipButtonsResize && !settings.boxLocked
        configureReader()
        renderNow()
        guard running else { return }
        let new = EngineConfig(settings, mode: runMode)
        if new.input != cfg.input && runMode == .camera {
            // Kamera ↔ mikrofon geçişi farklı donanım ister: temiz bir yeniden başlatma.
            stop()
            status = "Kaynak değişti — tekrar Başlat'a dokun"
            return
        }
        let recognitionChanged = new.input != cfg.input || new.asr != cfg.asr || new.sourceLang != cfg.sourceLang
        let changed = recognitionChanged || new.translator != cfg.translator || new.targetLang != cfg.targetLang
            || new.displayMode != cfg.displayMode
            || new.geminiKey != cfg.geminiKey || new.openaiKey != cfg.openaiKey || new.claudeKey != cfg.claudeKey
            || new.geminiModel != cfg.geminiModel || new.openaiModel != cfg.openaiModel
            || new.openaiASRModel != cfg.openaiASRModel || new.claudeModel != cfg.claudeModel
        guard changed else { return }
        if let problem = validate(new) { status = problem; return }
        if new.usesAppleASR && !cfg.usesAppleASR && !AppleRecognizer.isAuthorized {
            status = "Ses moduna geçmek için durdurup yeniden başlat (izin gerekiyor)."
            return
        }
        cfg = new
        service = TranslationService(config: new)
        if recognitionChanged {
            resetCaptions()
            _ = startRecognition()
        } else {
            // Yeni dil/motor/gösterimle mevcut satırları yeniden çevir.
            for i in committed.indices { committed[i].translatedSource = "" }
            live.translatedSource = ""
            for s in committed.suffix(2) { translate(s.id) }
            translate(live.id)
        }
        status = "Ayarlar uygulandı"
    }

    /// Kendi seslendirmemizi tekrar dinlememek için gelen sesi geçici olarak yok sayar.
    private var shouldIgnoreAudioForEcho: Bool {
        guard settings.speakEnabled, speaker.isBusy else { return false }
        // Kamera modunda kulaklık takılıysa hoparlörden yankı olmaz.
        if runMode == .camera && speaker.headphonesConnected { return false }
        return true
    }

    private func handleAudio(_ samples: [Int16]) {
        guard running, !screenMode else { return }
        lastAudioAt = Date()
        if paused || shouldIgnoreAudioForEcho { return }
        if let a = apple {
            a.append(samples)
        } else if let c = chunker {
            for chunk in c.push(samples) { sendCloud(chunk) }
        }
    }

    private func connectionChanged(_ connected: Bool) {
        broadcastConnected = connected
        guard runMode == .screen else { return }
        audioConnected = connected
        if running {
            status = connected ? connectedStatus : "Ekran yayını kapandı. Tekrar açmak için ⏺ simgesine dokun."
        } else if connected {
            status = "Yayın açık — çeviri için Başlat'a dokun"
        }
        scheduleRender()
    }

    // MARK: Görüntüdeki yazı (ekran ya da kamera)

    /// Alıcı kuyruğunda çağrılır.
    private func handleBroadcastFrame(_ frame: ScreenFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Kendi uygulamamız açıkken ekranda kendi ayarlarımız var; onları okumayalım.
            guard self.appInBackground else { return }
            if frame.isLandscape { self.lastLandscapeFrame = frame } else { self.lastPortraitFrame = frame }
            guard self.running, self.runMode == .screen, self.screenMode, !self.paused else { return }
            self.submitForReading(frame)
        }
    }

    private func handleCameraFrame(_ frame: ScreenFrame) {
        guard running, runMode == .camera, screenMode, !paused else { return }
        submitForReading(frame)
    }

    /// Altyazı yokken ya da tasarruf/ısınma durumunda daha seyrek okur.
    private var ocrInterval: TimeInterval {
        let active = Date().timeIntervalSince(lastCaptionAt) < 6
        var i: TimeInterval = active ? 0.4 : 1.0
        if saving { i *= 2 }
        if power.isCritical { i = max(i, 2.5) }
        return i
    }

    private func submitForReading(_ frame: ScreenFrame) {
        let now = Date()
        guard now.timeIntervalSince(lastOCRSubmit) >= ocrInterval else { return }
        lastOCRSubmit = now
        reader.submit(frame)
    }

    /// Tasarruf şu an etkin mi?
    var saving: Bool { power.saving(settings.batteryMode) }

    private func setVideoMode(_ m: AudioReceiver.VideoMode) {
        guard m != videoMode else { return }
        videoMode = m
        receiver.setVideoMode(m)
    }

    private func powerChanged() {
        configureReader()
        if running && runMode == .camera && cfg.input == .screen { camera.setFrameRate(saving ? 10 : 15) }
        objectWillChange.send()
    }

    private func handleMemoryWarning() {
        if UIApplication.shared.applicationState != .active {
            lastPortraitFrame = nil
            lastLandscapeFrame = nil
        }
        if committed.count > 10 { committed.removeFirst(committed.count - 10) }
    }

    private func handleOCR(_ lines: [OCRLine], frame: ScreenFrame) {
        guard running, screenMode, !paused else { return }
        let fresh: [String]
        if runMode == .camera {
            // Kamera modunda kullanıcı okuma alanını altyazıya göre seçer; alandaki yazılar altyazıdır
            // (oyun arayüzündeki sayılar, para, süre gibi yazılar hariç).
            fresh = lines.map { $0.text }.filter { !CaptionTracker.looksLikeInterface($0) }
        } else {
            guard appInBackground else { return }
            let (o, t) = displayTexts()
            let exclude = CaptionTracker.normalize(o + " " + t)
            fresh = captions.dynamicLines(lines, exclude: exclude)
        }
        guard !fresh.isEmpty else { return }
        lastCaptionAt = Date()
        let caption = fresh.joined(separator: " ")
        let added = captions.newWords(caption: caption, liveWords: liveWords)
        guard !added.isEmpty else { return }
        if live.original.isEmpty { segStart = Date() }
        liveWords.append(contentsOf: added)
        live.original = liveWords.joined(separator: " ")
        lastChange = Date()
        scheduleLiveTranslation()
        scheduleRender()
    }

    // MARK: Altyazı alanı seçicisi

    /// Başka uygulamadayken alınan son dikey/yatay ekran görüntüsü.
    func capturedShot(landscape: Bool) -> UIImage? {
        guard let f = landscape ? lastLandscapeFrame : lastPortraitFrame else { return nil }
        return ScreenTextReader.image(from: f)
    }

    /// Seçilen alanda ne okunduğunu gösterir.
    func previewRead(landscape: Bool, area: CGRect, completion: @escaping (String) -> Void) {
        guard let f = landscape ? lastLandscapeFrame : lastPortraitFrame else { completion(""); return }
        reader.recognizeOnce(f, area: area, sourceLang: settings.sourceLang) { lines in
            let text = lines.map { $0.text }
                .filter { !CaptionTracker.looksLikeInterface($0) }
                .joined(separator: " ")
            completion(text)
        }
    }

    /// Otomatik modda bulunan son video alanı.
    var detectedVideoArea: CGRect? { reader.lastDetectedArea }

    // MARK: Apple segmentleri

    private func applePartial(_ seg: Int, _ text: String) {
        guard running else { return }
        if seg == live.id {
            guard text != live.original else { return }
            if live.original.isEmpty { segStart = Date() }
            live.original = text
            lastChange = Date()
            recognizerErrors = 0
            scheduleLiveTranslation()
            scheduleRender()
        } else if let i = committed.firstIndex(where: { $0.id == seg }), !text.isEmpty {
            committed[i].original = text
        }
    }

    private func appleFinal(_ seg: Int, _ text: String?) {
        guard running else { return }
        if seg == live.id {
            // Tanıma kendiliğinden bitti (zaman aşımı/hata) → kaydet ve yeni segment aç.
            if let t = text, !t.isEmpty { live.original = t }
            let failedFast = text == nil && Date().timeIntervalSince(apple?.segmentStartedAt ?? Date()) < 1.5
            if failedFast { recognizerErrors += 1 }
            let delay = failedFast ? min(5.0, 0.5 * Double(recognizerErrors)) : 0
            commitLive(restart: true, delay: delay)
            if recognizerErrors >= 6 {
                status = "Ses tanıma çalışmıyor. Ayarlar > Genel > Klavye > Dikte açık mı? Bulut tanımayı da deneyebilirsin."
            }
        } else if let i = committed.firstIndex(where: { $0.id == seg }), let t = text, !t.isEmpty,
                  t != committed[i].original {
            committed[i].original = t
            if cfg.translationEnabled { translate(seg) } else { finalize(seg) }
        }
    }

    private func commitLive(restart: Bool, delay: Double = 0) {
        let old = live
        if let a = apple {
            if restart {
                if delay > 0 {
                    live = Segment(id: -1)  // geçici; yeni segment açılınca güncellenir
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self, self.running, let a2 = self.apple, a2 === a else { return }
                        a2.startSegment()
                        self.live = Segment(id: a2.segment)
                    }
                } else {
                    a.startSegment()
                    live = Segment(id: a.segment)
                }
            } else {
                a.cut()
                live = Segment(id: a.segment)
            }
        } else {
            if screenMode { captions.commit(words: liveWords.map(CaptionTracker.normalizeWord)) }
            live = Segment(id: nextLocalSegment())
            liveWords = []
        }
        let text = old.original.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            committed.append(old)
            if committed.count > 40 { committed.removeFirst(committed.count - 40) }
            debounce?.cancel()
            if !cfg.translationEnabled || (old.translatedSource == text && !old.translation.isEmpty) {
                finalize(old.id)
            } else {
                translate(old.id)
            }
        }
        scheduleRender()
    }

    /// Cümle kesinleşti: geçmişe yaz, seslendir.
    private func finalize(_ id: Int) {
        guard let i = segmentIndex(id) else { return }
        let seg = committed[i]
        if settings.historyEnabled {
            if let hid = historyIDs[id] {
                history.update(hid, original: seg.original, translation: seg.translation)
            } else {
                historyIDs[id] = history.add(original: seg.original, translation: seg.translation, source: historySource)
            }
        }
        guard settings.speakEnabled, !paused, !spoken.contains(id) else { return }
        spoken.insert(id)
        let useOriginal = settings.speakTarget == .original || !cfg.translationEnabled
        let text = useOriginal ? seg.original : seg.translation
        let lang = useOriginal ? cfg.speechSourceLanguage : cfg.speechTargetLanguage
        speaker.speak(text, language: lang, voiceID: useOriginal ? "" : settings.voiceID,
                      rate: Float(settings.speechRate))
    }

    private var historySource: String {
        if runMode == .camera { return cfg.input == .audio ? "Mikrofon" : "Kamera" }
        return cfg.input == .audio ? "Ekran sesi" : "Ekran altyazısı"
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        if (apple != nil || screenMode), !live.original.isEmpty, live.id > 0 {
            let stable = now.timeIntervalSince(lastChange)
            let duration = now.timeIntervalSince(segStart)
            let words = live.original.split(separator: " ").count
            let endsSentence = live.original.last.map { ".?!…。？！".contains($0) } ?? false
            let pause = screenMode ? 1.2 : 1.0
            if (endsSentence && stable >= 0.5) || stable >= pause || duration >= 15 || words >= 40 {
                commitLive(restart: false)
            }
        }
        if let c = chunker, now.timeIntervalSince(lastAudioAt) > 1.2, let rest = c.flush(minSeconds: 0.8) {
            sendCloud(rest)
        }
        if chunker != nil { applyCloud() }
        // Uzantıdan gelen kare sıklığını okuma ihtiyacına göre ayarla.
        if runMode == .screen && screenMode {
            setVideoMode(ocrInterval >= 0.9 ? .slow : .fast)
        }
        // Hata beklemesi bittiyse çevrilemeyen cümleleri yeniden dene.
        if !pendingRetry.isEmpty && now >= backoffUntil {
            let ids = pendingRetry
            pendingRetry.removeAll()
            for id in ids where id == live.id || segmentIndex(id) != nil { translate(id) }
        }
        if runMode == .screen && now.timeIntervalSince(lastRender) > 2.0 { renderNow(force: true) }
    }

    // MARK: - Çeviri

    private func scheduleLiveTranslation() {
        // Pil tasarrufunda ya da kullanıcı kapattıysa yalnızca biten cümleler çevrilir.
        guard !paused, cfg.translationEnabled, settings.liveTranslation, !saving else { return }
        debounce?.cancel()
        let id = live.id
        let w = DispatchWorkItem { [weak self] in self?.translate(id) }
        debounce = w
        let delay: Double
        switch cfg.translator {
        case .google: delay = screenMode ? 0.25 : 0.45
        case .apple: delay = 0.3
        default: delay = screenMode ? 0.6 : 0.9
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func segmentIndex(_ id: Int) -> Int? { committed.firstIndex { $0.id == id } }

    private func text(of id: Int) -> String? {
        if id == live.id { return live.original }
        return segmentIndex(id).map { committed[$0].original }
    }

    private func translatedSource(of id: Int) -> String? {
        if id == live.id { return live.translatedSource }
        return segmentIndex(id).map { committed[$0].translatedSource }
    }

    private func setTranslation(_ id: Int, source: String, translation: String) {
        if id == live.id {
            live.translation = translation
            live.translatedSource = source
        } else if let i = segmentIndex(id) {
            committed[i].translation = translation
            committed[i].translatedSource = source
        }
    }

    private func translate(_ id: Int) {
        guard running, cfg.translationEnabled, id > 0,
              let raw = text(of: id)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              translatedSource(of: id) != raw else { return }
        if Date() < backoffUntil { pendingRetry.insert(id); return }
        if inFlight.contains(id) { dirty.insert(id); return }
        inFlight.insert(id)
        let context = committed.filter { $0.id != id && $0.id < id }.suffix(2).map { $0.original }
        let svc = service
        Task { [weak self] in
            let outcome: Result<String, Error>
            do { outcome = .success(try await svc.translate(raw, context: Array(context))) } catch { outcome = .failure(error) }
            await MainActor.run {
                guard let self = self else { return }
                self.inFlight.remove(id)
                guard svc === self.service else { return }
                switch outcome {
                case .failure(let e):
                    self.translateFailures += 1
                    self.pendingRetry.insert(id)
                    if self.translateFailures >= 2 {
                        let wait = min(30, pow(2, Double(self.translateFailures - 1)))
                        self.backoffUntil = Date().addingTimeInterval(wait)
                        self.status = "Çeviri hatası: \(e.localizedDescription) — \(Int(wait)) sn sonra tekrar denenecek"
                    } else {
                        self.status = "Çeviri hatası: \(e.localizedDescription)"
                    }
                case .success(let result):
                    self.translateFailures = 0
                    self.setTranslation(id, source: raw, translation: result)
                    if self.status.hasPrefix("Çeviri hatası") { self.status = self.connectedStatus }
                    // Kesinleşmiş cümlenin son hâli çevrildiyse geçmişe yaz ve seslendir.
                    if id != self.live.id,
                       self.text(of: id)?.trimmingCharacters(in: .whitespacesAndNewlines) == raw {
                        self.finalize(id)
                    }
                    self.scheduleRender()
                }
                if self.dirty.remove(id) != nil { self.translate(id) }
            }
        }
    }

    // MARK: - Bulut ses modu

    private func sendCloud(_ chunk: [Int16]) {
        guard running, !paused, Chunker.rms(chunk) > 0.006 else { return }
        guard cloudInFlight < 4 else { return }  // ağ çok yavaşsa eski parçaları atla
        let seq = nextSeq
        nextSeq += 1
        cloudPending[seq] = Date()
        cloudInFlight += 1
        let context = committed.suffix(2).map { $0.original }
        let svc = service
        Task { [weak self] in
            let outcome: Result<(String, String), Error>
            do { outcome = .success(try await svc.transcribeAndTranslate(chunk, context: Array(context))) } catch { outcome = .failure(error) }
            await MainActor.run {
                guard let self = self else { return }
                self.cloudInFlight = max(0, self.cloudInFlight - 1)
                guard svc === self.service else { return }
                var out: (String, String) = ("", "")
                switch outcome {
                case .failure(let e):
                    self.status = "Bulut hatası: \(e.localizedDescription)"
                case .success(let r):
                    out = r
                    if self.status.hasPrefix("Bulut hatası") { self.status = self.connectedStatus }
                }
                self.cloudPending[seq] = nil
                if seq >= self.applySeq { self.cloudDone[seq] = out }
                self.applyCloud()
            }
        }
    }

    private func applyCloud() {
        var changed = false
        while applySeq < nextSeq {
            if let r = cloudDone.removeValue(forKey: applySeq) {
                if !r.0.isEmpty || !r.1.isEmpty {
                    let id = 1_000_000 + applySeq
                    committed.append(Segment(id: id, original: r.0, translation: r.1, translatedSource: r.0))
                    if committed.count > 40 { committed.removeFirst(committed.count - 40) }
                    finalize(id)
                    changed = true
                }
                applySeq += 1
            } else if let t = cloudPending[applySeq], Date().timeIntervalSince(t) > 15 {
                cloudPending[applySeq] = nil
                applySeq += 1
            } else if cloudPending[applySeq] == nil {
                applySeq += 1  // atlanmış parça
            } else {
                break
            }
        }
        if changed { scheduleRender() }
    }

    // MARK: - Çizim

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.renderScheduled = false
            self?.renderNow()
        }
    }

    /// Kutuda gösterilecek (orijinal, çeviri) metinleri.
    private func displayTexts() -> (String, String) {
        let keep = max(2, settings.lines)
        let originals: [String]
        switch settings.displayMode {
        case .original: originals = committed.suffix(keep).map { $0.original } + [live.original]
        default: originals = committed.suffix(1).map { $0.original } + [live.original]
        }
        let translations = committed.suffix(keep).map { $0.translation } + [live.translation]
        let o = originals.filter { !$0.isEmpty }.joined(separator: " ")
        let t = settings.displayMode == .original ? "" : translations.filter { !$0.isEmpty }.joined(separator: " ")
        return (o, t)
    }

    func renderNow(force: Bool = false) {
        var (o, t) = displayTexts()
        if shownOriginal != o { shownOriginal = o }
        if shownTranslation != t { shownTranslation = t }
        // Kamera modunda kutu uygulamanın içinde gösterilir; PiP kutusu yalnızca ekran modunda.
        if running && runMode == .camera { return }
        var hint: String?
        if !running {
            o = ""; t = ""
            hint = "Canlı Çeviri\nBaşlat'a dokun"
        } else if o.isEmpty && t.isEmpty {
            if !broadcastConnected {
                hint = "Ekran yayını bekleniyor…\n“Yayını Başlat”a dokun"
            } else {
                hint = screenMode ? "📺 Altyazı bekleniyor…" : "🎧 Dinleniyor…"
            }
        }
        // Aynı içerik tekrar çizilmez (pil); kutunun canlı kalması için 2 sn'de bir yenilenir.
        let key = "\(o)|\(t)|\(hint ?? "")|\(running && paused)|\(styleVersion)"
        if !force && key == lastRenderKey && Date().timeIntervalSince(lastRender) < 2 { return }
        lastRenderKey = key
        lastRender = Date()
        if let pb = renderer.render(boxContent(original: o, translation: t, hint: hint)) { pip.enqueue(pb) }
    }

    /// Ayarlardaki kutu stiliyle içerik oluşturur.
    func boxContent(original: String, translation: String, hint: String? = nil) -> OverlayRenderer.Content {
        OverlayRenderer.Content(
            original: original, translation: translation, hint: hint, paused: running && paused,
            mode: settings.displayMode, lines: settings.lines, fontSize: CGFloat(settings.fontSize),
            centered: settings.centered, color: settings.textColor,
            background: settings.boxBackground, fontStyle: settings.fontStyle, bold: settings.boldText)
    }

    /// Ayarlar ekranındaki örnek kutu görüntüsü.
    func samplePreview() -> UIImage? {
        renderer.image(boxContent(original: "Hey, welcome back! Today we're exploring the city.",
                                  translation: "Hey, tekrar hoş geldin! Bugün şehri keşfediyoruz."))
    }
}
