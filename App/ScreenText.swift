import Foundation
import Vision
import CoreVideo
import UIKit

/// Ekranda okunan tek bir yazı satırı.
struct OCRLine {
    let text: String
    /// Vision koordinatı (sol alt köşe başlangıçlı, 0–1), okuma alanına göre
    let box: CGRect
}

/// Ekran karelerinden yazı okur (Vision). Meşgulken gelen kareler atlanır.
final class ScreenTextReader {
    private let queue = DispatchQueue(label: "canliceviri.ocr", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    /// Okuma alanı (sol üst köşe başlangıçlı, 0–1)
    private var area = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var languages: [String]?
    /// Otomatik video alanı algılama (ekran modu)
    private var autoArea = false
    private let motion = MotionRegionDetector()
    private var detectedArea: CGRect?
    /// Pil tasarrufunda hızlı (daha az enerji harcayan) tanıma seviyesi
    private var fast = false
    // Yalnızca OCR kuyruğunda kullanılır: değişmeyen kareyi tekrar okumamak için.
    private var lastSignature: [Float] = []
    private var lastOCRAt = Date.distantPast

    /// Okunan satırlar (ana iş parçacığında çağrılır).
    var onResult: (([OCRLine], ScreenFrame) -> Void)?

    func configure(area: CGRect, auto: Bool, sourceLang: String, fast wantsFast: Bool = false) {
        // Hızlı seviye yalnızca bazı Latin alfabeli dilleri destekler; desteklemiyorsa doğru seviyede kal.
        let fastLangs = wantsFast ? Self.visionLanguages(for: sourceLang, level: .fast) : nil
        let useFast = wantsFast && (sourceLang == "auto" ? false : fastLangs != nil)
        let langs = useFast ? fastLangs : Self.visionLanguages(for: sourceLang, level: .accurate)
        lock.lock()
        self.area = Self.clamp(area)
        if auto != autoArea { detectedArea = nil }
        autoArea = auto
        languages = langs
        fast = useFast
        lock.unlock()
    }

    /// Otomatik bulunan video alanı (yoksa nil).
    var lastDetectedArea: CGRect? {
        lock.lock(); defer { lock.unlock() }
        return autoArea ? detectedArea : nil
    }

    /// Yeni oturumda video alanını sıfırdan bul.
    func resetDetection() {
        lock.lock(); detectedArea = nil; lock.unlock()
        queue.async { self.motion.reset() }
    }

    /// Ekran modu için tam genişlikte yatay şerit.
    static func band(top: Double, bottom: Double) -> CGRect {
        let t = min(max(top, 0), 0.95)
        let b = min(max(bottom, t + 0.05), 1)
        return CGRect(x: 0, y: t, width: 1, height: b - t)
    }

    static func clamp(_ r: CGRect) -> CGRect {
        let x = min(max(r.minX, 0), 0.95)
        let y = min(max(r.minY, 0), 0.95)
        let w = min(max(r.width, 0.05), 1 - x)
        let h = min(max(r.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Kareyi sıraya koyar; önceki kare hâlâ işleniyorsa atlar.
    func submit(_ frame: ScreenFrame) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        let manual = area, langs = languages, auto = autoArea, useFast = fast
        lock.unlock()
        queue.async {
            var target: CGRect? = manual
            if auto {
                // Videonun oynadığı (sürekli değişen) bölgeyi bul; başlık, yorum, menü gibi sabit yerleri okuma.
                let region = self.motion.update(frame)
                self.lock.lock(); self.detectedArea = region; self.lock.unlock()
                target = region.map(Self.clamp)
            }
            var lines: [OCRLine] = []
            if let t = target {
                // Okuma alanı bir önceki okumadan beri neredeyse hiç değişmediyse (durdurulmuş video,
                // aynı altyazı) yazı tanımayı atla: pil ve işlemci tasarrufu.
                let sig = Self.signature(frame, area: t)
                let unchanged = Self.similar(sig, self.lastSignature) && Date().timeIntervalSince(self.lastOCRAt) < 3
                if !unchanged {
                    lines = Self.recognize(frame, area: t, languages: langs, fast: useFast)
                    self.lastSignature = sig
                    self.lastOCRAt = Date()
                }
            }
            self.lock.lock(); self.busy = false; self.lock.unlock()
            DispatchQueue.main.async { self.onResult?(lines, frame) }
        }
    }

    /// Önizleme için tek seferlik okuma (meşguliyetten bağımsız).
    func recognizeOnce(_ frame: ScreenFrame, area: CGRect, sourceLang: String,
                       completion: @escaping ([OCRLine]) -> Void) {
        let a = Self.clamp(area)
        let langs = Self.visionLanguages(for: sourceLang)
        queue.async {
            let lines = Self.recognize(frame, area: a, languages: langs, fast: false)
            DispatchQueue.main.async { completion(lines) }
        }
    }

    /// Okuma alanının kaba parlaklık haritası (16×8).
    private static func signature(_ f: ScreenFrame, area: CGRect) -> [Float] {
        let raw = MotionRegionDetector.raw(fromOriented: area, f.orientation)
        let x0 = Int(raw.minX * CGFloat(f.width)), y0 = Int(raw.minY * CGFloat(f.height))
        let w = max(16, Int(raw.width * CGFloat(f.width))), h = max(8, Int(raw.height * CGFloat(f.height)))
        let gx = 16, gy = 8
        var out = [Float](repeating: 0, count: gx * gy)
        f.pixels.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let p = buf.bindMemory(to: UInt8.self)
            for cy in 0..<gy {
                for cx in 0..<gx {
                    var sum = 0, n = 0
                    let sx = x0 + cx * w / gx, ex = x0 + (cx + 1) * w / gx
                    let sy = y0 + cy * h / gy, ey = y0 + (cy + 1) * h / gy
                    var y = sy
                    while y < ey && y < f.height {
                        var x = sx
                        while x < ex && x < f.width { sum += Int(p[y * f.width + x]); n += 1; x += 3 }
                        y += 3
                    }
                    out[cy * gx + cx] = Float(sum) / Float(max(n, 1))
                }
            }
        }
        return out
    }

    private static func similar(_ a: [Float], _ b: [Float]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: Float = 0
        for i in 0..<a.count { diff += abs(a[i] - b[i]) }
        return diff / Float(a.count) < 1.5
    }

    private static func visionLanguages(for source: String,
                                        level: VNRequestTextRecognitionLevel = .accurate) -> [String]? {
        guard source != "auto" else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let lang = source.split(separator: "-").first.map(String.init) ?? source
        if supported.contains(source) { return [source] }
        if let match = supported.first(where: { $0.hasPrefix(lang) }) { return [match] }
        return nil
    }

    private static func recognize(_ f: ScreenFrame, area: CGRect, languages: [String]?, fast: Bool) -> [OCRLine] {
        guard let pb = makePixelBuffer(f) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = true
        req.minimumTextHeight = 0.012
        if let l = languages {
            req.recognitionLanguages = l
        } else {
            req.automaticallyDetectsLanguage = true
        }
        // Vision'da y ekseni aşağıdan yukarıdır.
        req.regionOfInterest = CGRect(x: area.minX, y: 1 - area.maxY, width: area.width, height: area.height)
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: f.orientation, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        let observations = req.results ?? []
        let lines: [OCRLine] = observations.compactMap { o in
            guard let c = o.topCandidates(1).first, c.confidence >= 0.4 else { return nil }
            let t = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : OCRLine(text: t, box: o.boundingBox)
        }
        // Yukarıdan aşağıya, soldan sağa sırala.
        return lines.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.01 { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
    }

    private static func makePixelBuffer(_ f: ScreenFrame) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, f.width, f.height, kCVPixelFormatType_OneComponent8,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        f.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let s = src.baseAddress else { return }
            for y in 0..<f.height {
                memcpy(dst + y * bpr, s + y * f.width, f.width)
            }
        }
        return pb
    }

    /// Kareyi önizleme için görüntüye çevirir (döndürme uygulanmış).
    static func image(from f: ScreenFrame) -> UIImage? {
        guard let provider = CGDataProvider(data: f.pixels as CFData),
              let cg = CGImage(width: f.width, height: f.height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: f.width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: uiOrientation(f.orientation))
    }

    private static func uiOrientation(_ o: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch o {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

/// Ekran karelerinde sürekli değişen (video oynayan) bölgeyi bulur.
/// Dikey YouTube'da üstteki oynatıcıyı, yatayda tüm ekranı otomatik seçer; sabit arayüz yazıları dışarıda kalır.
final class MotionRegionDetector {
    private let columns = 24
    private var cols = 0, rows = 0
    private var prev: [Float] = []
    private var heat: [Float] = []
    private var key = ""
    private var lastRegion: CGRect?

    func reset() {
        prev = []; heat = []; key = ""; lastRegion = nil
    }

    /// Video bölgesi (sol üst köşe başlangıçlı, 0–1, görüntünün dik hâline göre). Henüz bulunamadıysa nil.
    func update(_ f: ScreenFrame) -> CGRect? {
        let k = "\(f.width)x\(f.height)-\(f.orientation.rawValue)"
        if k != key { reset(); key = k }   // döndürme ya da boyut değişti: baştan öğren
        let cell = max(4, f.width / columns)
        let c = f.width / cell, r = f.height / cell
        guard c > 2, r > 2 else { return lastRegion }
        var means = [Float](repeating: 0, count: c * r)
        f.pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for cy in 0..<r {
                for cx in 0..<c {
                    var sum = 0, n = 0
                    var y = cy * cell
                    while y < (cy + 1) * cell {
                        let row = y * f.width
                        var x = cx * cell
                        while x < (cx + 1) * cell { sum += Int(p[row + x]); n += 1; x += 2 }
                        y += 2
                    }
                    means[cy * c + cx] = Float(sum) / Float(max(n, 1))
                }
            }
        }
        guard prev.count == means.count else {
            prev = means; heat = [Float](repeating: 0, count: means.count); cols = c; rows = r
            return lastRegion
        }
        var active = [Bool](repeating: false, count: means.count)
        for i in 0..<means.count {
            let moving = abs(means[i] - prev[i]) > 3
            heat[i] = heat[i] * 0.93 + (moving ? 1 : 0)
            active[i] = heat[i] > 0.35
        }
        prev = means

        // Bağlı bölgeleri bul.
        struct Comp { var count = 0; var minX = Int.max; var minY = Int.max; var maxX = -1; var maxY = -1 }
        var visited = [Bool](repeating: false, count: active.count)
        var comps: [Comp] = []
        var stack: [Int] = []
        for start in 0..<active.count where active[start] && !visited[start] {
            var comp = Comp()
            stack.append(start); visited[start] = true
            while let i = stack.popLast() {
                let x = i % c, y = i / c
                comp.count += 1
                comp.minX = min(comp.minX, x); comp.maxX = max(comp.maxX, x)
                comp.minY = min(comp.minY, y); comp.maxY = max(comp.maxY, y)
                let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                for (nx, ny) in neighbors where nx >= 0 && ny >= 0 && nx < c && ny < r {
                    let j = ny * c + nx
                    if active[j] && !visited[j] { visited[j] = true; stack.append(j) }
                }
            }
            comps.append(comp)
        }
        let minCells = max(6, (c * r) / 50)
        let big = comps.filter { $0.count >= minCells }.sorted { $0.count > $1.count }
        guard var main = big.first else { return lastRegion }
        // Videonun hemen altındaki/üstündeki parçaları (ör. altyazı satırı) birleştir; uzaktaki kutuyu değil.
        for other in big.dropFirst() {
            let overlapX = min(main.maxX, other.maxX) - max(main.minX, other.minX) + 1
            let narrower = min(main.maxX - main.minX, other.maxX - other.minX) + 1
            let gap = max(other.minY - main.maxY, main.minY - other.maxY)
            if overlapX * 2 >= narrower && gap <= 4 {
                main.minX = min(main.minX, other.minX); main.maxX = max(main.maxX, other.maxX)
                main.minY = min(main.minY, other.minY); main.maxY = max(main.maxY, other.maxY)
            }
        }
        let x0 = max(0, main.minX - 1), x1 = min(c - 1, main.maxX + 1)
        let y0 = max(0, main.minY - 1), y1 = min(r - 1, main.maxY + 2)
        let rawRect = CGRect(x: CGFloat(x0) / CGFloat(c), y: CGFloat(y0) / CGFloat(r),
                             width: CGFloat(x1 - x0 + 1) / CGFloat(c), height: CGFloat(y1 - y0 + 1) / CGFloat(r))
        let region = Self.oriented(rawRect, f.orientation)
        lastRegion = region
        return region
    }

    /// `oriented` işleminin tersi: dik görüntüdeki dikdörtgeni ham görüntüye taşır.
    static func raw(fromOriented o: CGRect, _ orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .right, .rightMirrored:
            return CGRect(x: o.minY, y: 1 - o.minX - o.width, width: o.height, height: o.width)
        case .left, .leftMirrored:
            return CGRect(x: 1 - o.minY - o.height, y: o.minX, width: o.height, height: o.width)
        case .down, .downMirrored:
            return CGRect(x: 1 - o.maxX, y: 1 - o.maxY, width: o.width, height: o.height)
        default:
            return o
        }
    }

    /// Ham görüntüdeki dikdörtgeni, görüntü dik çevrildiğindeki konumuna taşır.
    static func oriented(_ r: CGRect, _ o: CGImagePropertyOrientation) -> CGRect {
        switch o {
        case .right, .rightMirrored:
            return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case .left, .leftMirrored:
            return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        case .down, .downMirrored:
            return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        default:
            return r
        }
    }
}

/// Okunan satırlardan gerçek altyazıyı ayıklar ve kayan (roll-up) altyazıları tek metinde birleştirir.
final class CaptionTracker {
    private struct Seen { var firstSeen: Date; var lastSeen: Date; var candidate: Bool }
    private var seen: [String: Seen] = [:]
    private var baselinePending = true
    /// Daha önce görülüp kaybolan yazıların son görülme zamanı (tekrar belirirse arayüz yazısıdır).
    private var everSeen: [String: Date] = [:]
    /// Arayüz olduğu anlaşılan yazılar (bölüm adı, düğme vb.) — oturum boyunca yok sayılır.
    private var uiTexts = Set<String>()
    /// Önceki segmentlerin son kelimeleri (normalleştirilmiş) — kayan altyazı örtüşmesi için.
    private var tail: [String] = []

    /// Yeni oturum veya uygulamaya dönüş: ekranda o an duran yazılar "sabit" kabul edilir.
    func resetBaseline() {
        seen.removeAll()
        baselinePending = true
    }

    func resetAll() {
        resetBaseline()
        tail.removeAll()
        everSeen.removeAll()
        uiTexts.removeAll()
    }

    /// Segment kapandığında son kelimelerini sakla.
    func commit(words: [String]) {
        tail = Array((tail + words).suffix(40))
    }

    /// Ekranda yeni beliren (sabit olmayan) satırları döndürür.
    /// - Parameter exclude: Kendi kutumuzda gösterilen metin (normalleştirilmiş) — kendi yazımızı okumayalım.
    func dynamicLines(_ lines: [OCRLine], exclude: String, now: Date = Date()) -> [String] {
        var result: [String] = []
        let isBaseline = baselinePending
        baselinePending = false
        for line in lines {
            let n = Self.normalize(line.text)
            guard n.count >= 2 else { continue }
            if !exclude.isEmpty && exclude.contains(n) { continue }
            if uiTexts.contains(n) || Self.looksLikeInterface(line.text) { continue }
            if seen[n] == nil, let last = everSeen[n], now.timeIntervalSince(last) > 3 {
                // Kaybolup aynen geri gelen yazı altyazı değil, arayüzdür (bölüm adı, düğme vb.).
                uiTexts.insert(n)
                continue
            }
            everSeen[n] = now
            if var s = seen[n] {
                s.lastSeen = now
                // 12 sn'den uzun ekranda kalan yazı altyazı değildir (başlık, menü vb.)
                if now.timeIntervalSince(s.firstSeen) > 12 { s.candidate = false }
                seen[n] = s
                if s.candidate { result.append(line.text) }
            } else {
                seen[n] = Seen(firstSeen: now, lastSeen: now, candidate: !isBaseline)
                if !isBaseline { result.append(line.text) }
            }
        }
        // Ekrandan kaybolan yazıları unut (geri gelirse yeniden "yeni" sayılır).
        seen = seen.filter { now.timeIntervalSince($0.value.lastSeen) < 2.5 }
        if everSeen.count > 2000 { everSeen = everSeen.filter { now.timeIntervalSince($0.value) < 600 } }
        return result
    }

    private static let interfaceWords: Set<String> = [
        "görüntüleme", "görüntülenme", "beğeni", "beğenme", "abone", "abonelik", "yorum", "yorumlar",
        "views", "view", "likes", "subscribers", "subscriber", "comments", "önce", "ago",
    ]
    private static let interfaceLabels: Set<String> = [
        "abone ol", "subscribe", "paylaş", "share", "remix", "indir", "download", "kaydet", "save",
        "yorumlar", "comments", "shorts", "canlı", "live", "atla", "skip", "skip ad", "reklamı atla",
        "sponsorlu", "sponsored", "daha fazla", "more", "katıl", "join",
    ]

    /// YouTube ve benzeri uygulamaların arayüz yazılarına benziyor mu? (süre, @kanal, sayılar, kesik başlık…)
    static func looksLikeInterface(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        if t.hasSuffix("…") || t.hasSuffix("...") { return true }        // kesilmiş başlık
        if t.contains("@") || t.contains("#") { return true }            // kanal adı, etiket
        if t.lowercased().hasPrefix("http") || t.contains("www.") { return true }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        if letters < 2 { return true }                                    // "2:27 / 18:27", "1,5 B"
        if digits > 0 && Double(letters) / Double(max(1, t.count)) < 0.45 { return true }
        let norm = normalize(t)
        if interfaceLabels.contains(norm) { return true }
        if digits > 0 {
            let words = Set(norm.split(separator: " ").map(String.init))
            if !words.isDisjoint(with: interfaceWords) { return true }   // "70.487 görüntüleme", "7 sa. önce"
        }
        return false
    }

    /// Mevcut canlı metne eklenecek yeni kelimeleri hesaplar.
    /// - Returns: eklenecek kelimeler (orijinal yazımıyla); hiçbir yeni şey yoksa boş dizi.
    func newWords(caption: String, liveWords: [String]) -> [String] {
        let words = caption.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let norm = words.map(Self.normalizeWord)
        guard !norm.isEmpty else { return [] }
        let liveNorm = liveWords.map(Self.normalizeWord)
        let context = tail + liveNorm

        // Altyazı zaten okunmuş metnin içinde geçiyorsa yeni bir şey yok.
        if Self.containsRun(context, norm) { return [] }

        // Bağlamın sonu ile altyazının başı örtüşüyor mu? (kayan altyazı)
        var k = 0
        let maxK = min(context.count, norm.count)
        if maxK > 0 {
            for kk in stride(from: maxK, through: 1, by: -1) {
                if Self.equalRuns(Array(context.suffix(kk)), Array(norm.prefix(kk))) { k = kk; break }
            }
        }
        // Tek kelimelik tesadüfi örtüşmeyi ("the" gibi) kabul etme.
        if k == 1 && !(liveNorm.count == 1 || norm.count == 1) { k = 0 }
        return Array(words[k...])
    }

    // MARK: Yardımcılar

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func normalizeWord(_ w: String) -> String {
        String(w.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistanceAtMostOne(Array(a), Array(b))
    }

    private static func editDistanceAtMostOne(_ a: [Character], _ b: [Character]) -> Bool {
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        edits += (a.count - i) + (b.count - j)
        return edits <= 1
    }

    private static func equalRuns(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) where !similar(x, y) { return false }
        return true
    }

    private static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if equalRuns(Array(haystack[start..<(start + needle.count)]), needle) { return true }
        }
        return false
    }
}
