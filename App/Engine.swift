import Foundation
import UIKit
import Combine

struct Segment {
    var id: Int
    var original: String = ""
    var translation: String = ""
    var translatedSource: String = ""
}

/// Ses → yazı → çeviri → kutu akışını yöneten ana sınıf. Tüm durum ana iş parçacığında tutulur.
final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var running = false
    @Published private(set) var audioConnected = false
    @Published private(set) var status = "Hazır"
    @Published private(set) var paused = false
    @Published private(set) var boxVisible = false

    let settings = AppSettings.shared
    let pip = PiPManager()

    private let renderer = OverlayRenderer()
    private let receiver = AudioReceiver()
    private let keepAlive = KeepAlive()
    private var cfg: EngineConfig
    private var service: TranslationService
    private var apple: AppleRecognizer?
    private var chunker: Chunker?
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Altyazı durumu
    private var committed: [Segment] = []
    private var live = Segment(id: 0)
    private var lastChange = Date()
    private var segStart = Date()
    private var lastAudioAt = Date.distantPast
    private var recognizerErrors = 0

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

        receiver.onAudio = { [weak self] samples in
            DispatchQueue.main.async { self?.handleAudio(samples) }
        }
        receiver.onConnectionChange = { [weak self] connected in
            DispatchQueue.main.async { self?.connectionChanged(connected) }
        }
        receiver.ensureListening()

        settings.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.receiver.ensureListening()
            self?.renderNow()
        }

        DispatchQueue.main.async { [weak self] in self?.renderNow() }
    }

    // MARK: - Başlat / Durdur

    func start() {
        guard !running else { return }
        let c = EngineConfig(settings)
        if let problem = validate(c) { status = problem; return }
        if c.asr == .apple {
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
        if c.asr == .apple && c.sourceIsAuto { return "Apple ses tanıma için videonun dilini seçmelisin." }
        if c.translator == .apple && c.sourceIsAuto { return "Apple Çeviri için videonun dilini seçmelisin." }
        if c.translator == .apple, #unavailable(iOS 26.0) { return "Apple Çeviri için iOS 26 gerekli." }
        let needsGemini = c.asr == .gemini || c.translator == .gemini
        let needsOpenAI = c.asr == .openai || c.translator == .openai
        if needsGemini && c.geminiKey.isEmpty { return "Gemini API anahtarını gir (aşağıda)." }
        if needsOpenAI && c.openaiKey.isEmpty { return "OpenAI API anahtarını gir (aşağıda)." }
        if c.translator == .claude && c.claudeKey.isEmpty { return "Claude API anahtarını gir (aşağıda)." }
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
        status = audioConnected ? "Ses alınıyor" : "Ses yakalama bekleniyor…"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        renderNow()
        pip.start()

        // Ses yakalama (ekran yayını) açık değilse sistem penceresini aç.
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

    private func setPaused(_ p: Bool) {
        paused = p
        if p { debounce?.cancel() }
        status = p ? "Duraklatıldı (kutudaki ▶︎ ile devam)" : (audioConnected ? "Ses alınıyor" : status)
        renderNow()
    }

    // MARK: - Tanıma

    private func startRecognition() -> Bool {
        stopRecognition()
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
    }

    private func resetCaptions() {
        committed.removeAll()
        live = Segment(id: 0)
        inFlight.removeAll()
        dirty.removeAll()
        nextSeq = 0
        applySeq = 0
        cloudPending.removeAll()
        cloudDone.removeAll()
        cloudInFlight = 0
    }

    private func settingsChanged() {
        renderNow()
        guard running else { return }
        let new = EngineConfig(settings)
        let recognitionChanged = new.asr != cfg.asr || new.sourceLang != cfg.sourceLang
        let changed = recognitionChanged || new.translator != cfg.translator || new.targetLang != cfg.targetLang
            || new.geminiKey != cfg.geminiKey || new.openaiKey != cfg.openaiKey || new.claudeKey != cfg.claudeKey
            || new.geminiModel != cfg.geminiModel || new.openaiModel != cfg.openaiModel
            || new.openaiASRModel != cfg.openaiASRModel || new.claudeModel != cfg.claudeModel
        guard changed else { return }
        if let problem = validate(new) { status = problem; return }
        cfg = new
        service = TranslationService(config: new)
        if recognitionChanged {
            resetCaptions()
            _ = startRecognition()
        } else {
            // Yeni dil/motorla mevcut satırları yeniden çevir.
            for i in committed.indices { committed[i].translatedSource = "" }
            live.translatedSource = ""
            for s in committed.suffix(2) { translate(s.id) }
            translate(live.id)
        }
        status = "Ayarlar uygulandı"
    }

    private func handleAudio(_ samples: [Int16]) {
        guard running else { return }
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
            status = connected ? "Ses alınıyor" : "Ses yakalama kapandı. Tekrar açmak için ⏺ simgesine dokun."
        } else if connected {
            status = "Ses geliyor — çeviri için Başlat'a dokun"
        }
        scheduleRender()
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
        if apple != nil, !live.original.isEmpty, live.id > 0 {
            let stable = now.timeIntervalSince(lastChange)
            let duration = now.timeIntervalSince(segStart)
            let words = live.original.split(separator: " ").count
            let endsSentence = live.original.last.map { ".?!…。？！".contains($0) } ?? false
            if (endsSentence && stable >= 0.5) || stable >= 1.0 || duration >= 15 || words >= 40 {
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
        guard !paused else { return }
        debounce?.cancel()
        let id = live.id
        let w = DispatchWorkItem { [weak self] in self?.translate(id) }
        debounce = w
        let delay: Double
        switch cfg.translator {
        case .google: delay = 0.45
        case .apple: delay = 0.3
        default: delay = 0.9
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
        guard running, id > 0,
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
                    if self.status.hasPrefix("Çeviri hatası") { self.status = "Ses alınıyor" }
                    self.scheduleRender()
                }
                if self.dirty.remove(id) != nil { self.translate(id) }
            }
        }
    }

    // MARK: - Bulut modu

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
                    if self.status.hasPrefix("Bulut hatası") { self.status = "Ses alınıyor" }
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

    private func displayTexts() -> (String, String) {
        let originals = committed.suffix(1).map { $0.original } + [live.original]
        let translations = committed.suffix(2).map { $0.translation } + [live.translation]
        let o = originals.filter { !$0.isEmpty }.joined(separator: " ")
        let t = translations.filter { !$0.isEmpty }.joined(separator: " ")
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
            hint = audioConnected ? "🎧 Dinleniyor…" : "Ses yakalama bekleniyor…\n“Yayını Başlat”a dokun"
        }
        let content = OverlayRenderer.Content(
            original: o, translation: t, hint: hint, paused: running && paused,
            showOriginal: settings.showOriginal, fontSize: CGFloat(settings.fontSize),
            aspect: settings.boxShape.aspect)
        if let pb = renderer.render(content) { pip.enqueue(pb) }
    }
}
