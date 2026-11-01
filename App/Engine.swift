import Foundation
import UIKit
import Combine

struct Segment {
    var id: Int
    var original: String = ""
    var translation: String = ""
    var translatedSource: String = ""
}

/// Ses/ekran → yazı → çeviri → kutu akışını yöneten ana sınıf. Tüm durum ana iş parçacığında tutulur.
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var running = false
    @Published private(set) var audioConnected = false
    @Published private(set) var status = "Hazır"
    @Published private(set) var paused = false
    @Published private(set) var boxVisible = false
    /// Altyazı alanı ayarı için son ekran görüntüsü ve orada okunan yazı.
    @Published private(set) var ocrPreview: UIImage?
    @Published private(set) var ocrPreviewText = ""

    let settings = AppSettings.shared
    let pip = PiPManager()

    private let renderer = OverlayRenderer()
    private let receiver = AudioReceiver()
    private let keepAlive = KeepAlive()
    private let reader = ScreenTextReader()
    private let captions = CaptionTracker()
    private var cfg: EngineConfig
    private var service: TranslationService
    private var apple: AppleRecognizer?
    private var chunker: Chunker?
    private var screenMode = false
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Altyazı durumu
    private var committed: [Segment] = []
    private var live = Segment(id: 0)
    private var liveWords: [String] = []
    private var localSegment = 2_000_000
    private var lastChange = Date()
    private var segStart = Date()
    private var lastAudioAt = Date.distantPast
    private var recognizerErrors = 0

    // Uygulama durumu (ekran okuma yalnızca başka uygulamadayken yapılır)
    private var appInBackground = false
    private var lastOutsideFrame: ScreenFrame?
    private var previewFrame: ScreenFrame?

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

    private init() {
        cfg = EngineConfig(AppSettings.shared)
        service = TranslationService(config: cfg)

        pip.onUserClosed = { [weak self] in self?.stop() }
        pip.onPauseToggled = { [weak self] p in self?.setPaused(p) }
        pip.onStatus = { [weak self] s in self?.status = s }
        pip.onActiveChanged = { [weak self] active in self?.boxVisible = active }
        pip.onSkip = { [weak self] forward in
            guard let self = self, self.settings.pipButtonsResize else { return }
            self.settings.changeLines(by: forward ? 1 : -1)
            self.renderNow()
        }
        pip.showsSkipButtons = settings.pipButtonsResize

        receiver.onAudio = { [weak self] samples in
            DispatchQueue.main.async { self?.handleAudio(samples) }
        }
        receiver.onFrame = { [weak self] frame in
            self?.handleFrameOnReceiverQueue(frame)
        }
        receiver.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.connectionChanged(connected) }
        }
        receiver.ensureListening()

        reader.onResult = { [weak self] lines, frame in self?.handleOCR(lines, frame: frame) }
        reader.configure(top: settings.ocrTop, bottom: settings.ocrBottom, sourceLang: settings.sourceLang)

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
            // Başka uygulamadayken alınan son kareyi altyazı alanı ayarı için göster.
            if let f = self.lastOutsideFrame {
                self.previewFrame = f
                self.ocrPreview = ScreenTextReader.image(from: f)
                self.refreshPreviewText()
            }
        }
        appInBackground = UIApplication.shared.applicationState == .background

        DispatchQueue.main.async { [weak self] in self?.renderNow() }
    }

    // MARK: - Başlat / Durdur

    func start() {
        guard !running else { return }
        let c = EngineConfig(settings)
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
        if needsGemini && c.geminiKey.isEmpty { return "Gemini API anahtarını gir (aşağıda)." }
        if needsOpenAI && c.openaiKey.isEmpty { return "OpenAI API anahtarını gir (aşağıda)." }
        if needsClaude && c.claudeKey.isEmpty { return "Claude API anahtarını gir (aşağıda)." }
        return nil
    }

    private func begin(_ c: EngineConfig) {
        do {
            try keepAlive.start()
        } catch {
            status = "Ses oturumu açılamadı: \(error.localizedDescription)"
            return
        }
        receiver.ensureListening()
        cfg = c
        service = TranslationService(config: c)
        resetCaptions()
        guard startRecognition() else { keepAlive.stop(); return }

        running = true
        paused = false
        pip.paused = false
        pip.autoStartWhenBackgrounded = true
        pip.showsSkipButtons = settings.pipButtonsResize
        status = audioConnected ? connectedStatus : "Ekran yayını bekleniyor…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        renderNow()
        pip.start()

        // Ekran yayını açık değilse sistem penceresini aç.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self = self, self.running, !self.audioConnected else { return }
            BroadcastPicker.present()
        }
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        receiver.setVideoEnabled(false)
        receiver.requestBroadcastStop()
        stopRecognition()
        pip.autoStartWhenBackgrounded = false
        pip.stop()
        keepAlive.stop()
        status = "Durduruldu"
        renderNow()
    }

    func openBroadcastPicker() { BroadcastPicker.present() }

    func showBox() {
        guard running else { return }
        renderNow()
        pip.start()
    }

    private var connectedStatus: String {
        screenMode ? "Ekrandaki altyazı okunuyor" : "Ses alınıyor"
    }

    private func setPaused(_ p: Bool) {
        paused = p
        if p { debounce?.cancel() }
        status = p ? "Duraklatıldı (kutudaki ▶︎ ile devam)" : (audioConnected ? connectedStatus : status)
        renderNow()
    }

    // MARK: - Tanıma

    private func startRecognition() -> Bool {
        stopRecognition()
        live = Segment(id: nextLocalSegment())
        liveWords = []
        if cfg.input == .screen {
            screenMode = true
            captions.resetAll()
            reader.configure(top: settings.ocrTop, bottom: settings.ocrBottom, sourceLang: cfg.sourceLang)
            receiver.setVideoEnabled(true)
            return true
        }
        screenMode = false
        receiver.setVideoEnabled(false)
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
        nextSeq = 0
        applySeq = 0
        cloudPending.removeAll()
        cloudDone.removeAll()
        cloudInFlight = 0
    }

    private func settingsChanged() {
        pip.showsSkipButtons = settings.pipButtonsResize
        reader.configure(top: settings.ocrTop, bottom: settings.ocrBottom,
                         sourceLang: running ? cfg.sourceLang : settings.sourceLang)
        refreshPreviewText()
        renderNow()
        guard running else { return }
        let new = EngineConfig(settings)
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

    private func handleAudio(_ samples: [Int16]) {
        guard running, !screenMode else { return }
        lastAudioAt = Date()
        if paused { return }
        if let a = apple {
            a.append(samples)
        } else if let c = chunker {
            for chunk in c.push(samples) { sendCloud(chunk) }
        }
    }

    private func connectionChanged(_ connected: Bool) {
        audioConnected = connected
        if running {
            status = connected ? connectedStatus : "Ekran yayını kapandı. Tekrar açmak için ⏺ simgesine dokun."
        } else if connected {
            status = "Yayın açık — çeviri için Başlat'a dokun"
        }
        scheduleRender()
    }

    // MARK: Ekrandaki altyazı

    /// Alıcı kuyruğunda çağrılır.
    private func handleFrameOnReceiverQueue(_ frame: ScreenFrame) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Kendi uygulamamız açıkken ekranda kendi ayarlarımız var; onları okumayalım.
            guard self.appInBackground else { return }
            self.lastOutsideFrame = frame
            guard self.running, self.screenMode, !self.paused else { return }
            self.reader.submit(frame)
        }
    }

    private func handleOCR(_ lines: [OCRLine], frame: ScreenFrame) {
        guard running, screenMode, appInBackground, !paused else { return }
        let (o, t) = displayTexts()
        let exclude = CaptionTracker.normalize(o + " " + t)
        let fresh = captions.dynamicLines(lines, exclude: exclude)
        guard !fresh.isEmpty else { return }
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

    /// Altyazı alanı ayarında, seçili alanda okunan yazıyı gösterir.
    private func refreshPreviewText() {
        guard let f = previewFrame else { return }
        reader.recognizeOnce(f, top: settings.ocrTop, bottom: settings.ocrBottom,
                             sourceLang: settings.sourceLang) { [weak self] lines in
            let text = lines.map { $0.text }.joined(separator: " ")
            self?.ocrPreviewText = text.isEmpty ? "(Bu alanda yazı bulunamadı)" : text
        }
    }

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
            translate(seg)
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
        if !old.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committed.append(old)
            if committed.count > 40 { committed.removeFirst(committed.count - 40) }
            debounce?.cancel()
            translate(old.id)
        }
        scheduleRender()
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
        if now.timeIntervalSince(lastRender) > 1.0 { renderNow() }
    }

    // MARK: - Çeviri

    private func scheduleLiveTranslation() {
        guard !paused, cfg.translationEnabled else { return }
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
                    self.status = "Çeviri hatası: \(e.localizedDescription)"
                case .success(let result):
                    self.setTranslation(id, source: raw, translation: result)
                    if self.status.hasPrefix("Çeviri hatası") { self.status = self.connectedStatus }
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
                    committed.append(Segment(id: 1_000_000 + applySeq, original: r.0, translation: r.1, translatedSource: r.0))
                    if committed.count > 40 { committed.removeFirst(committed.count - 40) }
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

    func renderNow() {
        lastRender = Date()
        var (o, t) = displayTexts()
        var hint: String?
        if !running {
            o = ""; t = ""
            hint = "Canlı Çeviri\nBaşlat'a dokun"
        } else if o.isEmpty && t.isEmpty {
            if !audioConnected {
                hint = "Ekran yayını bekleniyor…\n“Yayını Başlat”a dokun"
            } else {
                hint = screenMode ? "📺 Altyazı bekleniyor…" : "🎧 Dinleniyor…"
            }
        }
        let content = OverlayRenderer.Content(
            original: o, translation: t, hint: hint, paused: running && paused,
            mode: settings.displayMode, lines: settings.lines, fontSize: CGFloat(settings.fontSize),
            centered: settings.centered, color: settings.textColor)
        if let pb = renderer.render(content) { pip.enqueue(pb) }
    }
}
