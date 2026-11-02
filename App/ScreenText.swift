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
    /// Her iş biriminden sonra geçici Vision nesneleri bırakılır (sürekli okumada bellek birikmesin).
    private let queue = DispatchQueue(label: "canliceviri.ocr", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let lock = NSLock()
    private var busy = false
    /// Okuma alanları (sol üst köşe başlangıçlı, 0–1): dikey ve yatay görüntü için ayrı
    private var portraitArea = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var landscapeArea = CGRect(x: 0, y: 0, width: 1, height: 1)
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

    // Gerçek yön tespiti (ekran modu). iOS kareyi telefonun fiziksel yönüne göre etiketler; ekran döndürme
    // kilidi açıkken YouTube tam ekranı yatay çizse de "dikey" der. Yön, görüntüdeki yazılardan anlaşılır.
    private var probeEnabled = false                          // lock
    private var resolvedFor: CGImagePropertyOrientation?      // lock: kararın geçerli olduğu bildirilen yön
    private var resolvedActual: CGImagePropertyOrientation?   // lock: gerçek yön
    private var lastProbeAt = Date.distantPast                // yalnızca kuyrukta
    private var lastReadHadText = false                       // yalnızca kuyrukta: son okumada yazı çıktı mı
    private var probeSignature: [Float] = []                  // yalnızca kuyrukta: son yoklamadaki tüm kare

    /// Okunan satırlar (ana iş parçacığında çağrılır).
    var onResult: (([OCRLine], ScreenFrame) -> Void)?

    func configure(portrait: CGRect, landscape: CGRect, auto: Bool, sourceLang: String, fast wantsFast: Bool = false,
                   probeOrientation: Bool = false) {
        // Hızlı seviye yalnızca bazı Latin alfabeli dilleri destekler; desteklemiyorsa doğru seviyede kal.
        let fastLangs = wantsFast ? Self.visionLanguages(for: sourceLang, level: .fast) : nil
        let useFast = wantsFast && (sourceLang == "auto" ? false : fastLangs != nil)
        let langs = useFast ? fastLangs : Self.visionLanguages(for: sourceLang, level: .accurate)
        lock.lock()
        portraitArea = Self.clamp(portrait)
        landscapeArea = Self.clamp(landscape)
        if auto != autoArea { detectedArea = nil }
        autoArea = auto
        languages = langs
        fast = useFast
        if probeOrientation != probeEnabled {
            probeEnabled = probeOrientation
            resolvedFor = nil
            resolvedActual = nil
        }
        lock.unlock()
    }

    /// Görüntüden anlaşılan gerçek yön uygulanmış kare (karar yoksa kare olduğu gibi döner). Her iş parçacığından çağrılabilir.
    func resolve(_ f: ScreenFrame) -> ScreenFrame {
        lock.lock()
        let on = probeEnabled, reported = resolvedFor, actual = resolvedActual
        lock.unlock()
        guard on, let r = reported, let a = actual, r == f.orientation, a != f.orientation else { return f }
        return ScreenFrame(width: f.width, height: f.height, orientation: a, pixels: f.pixels, time: f.time)
    }

    /// Son kararla gerçek yön (test ve tanı için).
    var resolvedOrientation: CGImagePropertyOrientation? {
        lock.lock(); defer { lock.unlock() }
        return resolvedActual
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
        // Bozuk değerler (NaN/sonsuz) Vision'a gitmesin: tüm ekran.
        guard r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite, !r.isNull else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let x = min(max(r.minX, 0), 0.95)
        let y = min(max(r.minY, 0), 0.95)
        let w = min(max(r.width, 0.05), 1 - x)
        let h = min(max(r.height, 0.05), 1 - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Kareyi sıraya koyar; önceki kare hâlâ işleniyorsa atlar.
    func submit(_ raw: ScreenFrame) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        let portrait = portraitArea, landscape = landscapeArea
        let langs = languages, auto = autoArea, useFast = fast, probe = probeEnabled
        lock.unlock()
        queue.async {
            // Gerçek yönü (gerektiğinde) görüntüden belirle ve uygula.
            if probe { self.probeIfNeeded(raw, portrait: portrait, landscape: landscape, auto: auto) }
            let frame = self.resolve(raw)
            let manual = frame.isLandscape ? landscape : portrait
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
                    self.lastReadHadText = Self.hasMeaningfulText(lines)
                }
            } else {
                self.lastReadHadText = false
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

    // MARK: Gerçek yön tespiti

    /// Gerekiyorsa (ilk kare, cihaz yönü değişti, son okumada yazı çıkmadı ve görüntü değişti, ya da 6 sn geçti)
    /// aday yönlerde yalnızca okuma alanını hızlıca okuyup anlamlı yazının çıktığı yönü seçer. Şu anki yönde yazı
    /// varsa diğer yönler hiç denenmez: altyazı okunurken ek maliyet neredeyse sıfırdır. Yalnızca OCR kuyruğunda.
    private func probeIfNeeded(_ f: ScreenFrame, portrait: CGRect, landscape: CGRect, auto: Bool) {
        let now = Date()
        lock.lock(); let reported = resolvedFor, previous = resolvedActual; lock.unlock()
        let elapsed = now.timeIntervalSince(lastProbeAt)
        let sig = Self.signature(f, area: CGRect(x: 0, y: 0, width: 1, height: 1))
        let sameScene = Self.similar(sig, probeSignature)   // durgun ekran: sonuç değişmez
        let due = reported != f.orientation                   // ilk kare ya da cihazın bildirdiği yön değişti
            || (!lastReadHadText && !sameScene && elapsed > 1) // son okumada yazı yok: yön yanlış olabilir
            || elapsed > 6                                     // arada bir doğrula
        guard due else { return }
        lastProbeAt = now
        probeSignature = sig

        let current = (reported == f.orientation ? previous : nil) ?? f.orientation
        var candidates: [CGImagePropertyOrientation] = [current]
        for o in [f.orientation, .up, .left, .right] where !candidates.contains(o) { candidates.append(o) }
        var scores: [(CGImagePropertyOrientation, Float)] = []
        for o in candidates {
            let oriented = ScreenFrame(width: f.width, height: f.height, orientation: o, pixels: f.pixels, time: f.time)
            let area = auto ? CGRect(x: 0, y: 0, width: 1, height: 1) : (oriented.isLandscape ? landscape : portrait)
            let score = Self.textScore(oriented, area: area)
            scores.append((o, score))
            if o == current && score >= Self.minProbeScore { break }
        }
        let currentScore = scores.first?.1 ?? 0
        guard let best = scores.max(by: { $0.1 < $1.1 }) else { return }
        var actual = current
        if best.0 != current, best.1 >= Self.minProbeScore, best.1 > currentScore * 1.4 { actual = best.0 }
        lock.lock(); resolvedFor = f.orientation; resolvedActual = actual; lock.unlock()
    }

    /// Bir yönde "anlamlı yazı" puanı için alt sınır (≈ 15–20 harflik net bir altyazı satırı).
    static let minProbeScore: Float = 15

    /// Okunan satırlarda gerçek yazı var mı? (yanlış yönde okunan kırıntılar sayılmaz)
    static func hasMeaningfulText(_ lines: [OCRLine]) -> Bool {
        var letters = 0
        for l in lines { letters += l.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count }
        return letters >= 6
    }

    /// Verilen yönde, okuma alanında hızlı yazı tanıma puanı: güvenle okunan harf sayısı.
    private static func textScore(_ f: ScreenFrame, area: CGRect) -> Float {
        autoreleasepool {
            guard let crop = cropRect(f, area: area), let pb = makePixelBuffer(f, crop: crop) else { return 0 }
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = false
            req.minimumTextHeight = Float(min(0.1, 0.012 / max(0.05, Double(area.height))))
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: f.orientation, options: [:])
            do { try handler.perform([req]) } catch { return 0 }
            var score: Float = 0
            for obs in req.results ?? [] {
                guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { continue }
                let letters = c.string.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                if letters >= 3 { score += Float(letters) * c.confidence }
            }
            return score
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
        autoreleasepool { recognizeInPool(f, area: area, languages: languages, fast: fast) }
    }

    private static func recognizeInPool(_ f: ScreenFrame, area: CGRect, languages: [String]?, fast: Bool) -> [OCRLine] {
        // Yalnızca okuma alanını kopyala (tüm kareyi değil): daha az bellek trafiği, daha hızlı tanıma.
        guard let crop = cropRect(f, area: area), let pb = makePixelBuffer(f, crop: crop) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = true
        // Kırpılmış görüntüye göre: tüm ekranın ~%1,2'si kadar küçük yazıları atla (arayüz kırıntıları).
        req.minimumTextHeight = Float(min(0.1, 0.012 / max(0.05, Double(area.height))))
        if let l = languages {
            req.recognitionLanguages = l
        } else {
            req.automaticallyDetectsLanguage = true
        }
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

    /// Dik görüntüye göre verilen alanın ham karedeki piksel dikdörtgeni (çok küçükse nil).
    private static func cropRect(_ f: ScreenFrame, area: CGRect) -> (x: Int, y: Int, w: Int, h: Int)? {
        let raw = MotionRegionDetector.raw(fromOriented: area, f.orientation)
        let x0 = max(0, min(f.width - 1, Int((raw.minX * CGFloat(f.width)).rounded(.down))))
        let y0 = max(0, min(f.height - 1, Int((raw.minY * CGFloat(f.height)).rounded(.down))))
        let x1 = max(x0 + 1, min(f.width, Int((raw.maxX * CGFloat(f.width)).rounded(.up))))
        let y1 = max(y0 + 1, min(f.height, Int((raw.maxY * CGFloat(f.height)).rounded(.up))))
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return nil }
        return (x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// Karenin (ya da ham koordinatlardaki bir parçasının) gri piksel tamponu.
    private static func makePixelBuffer(_ f: ScreenFrame, crop: (x: Int, y: Int, w: Int, h: Int)?) -> CVPixelBuffer? {
        let c = crop ?? (x: 0, y: 0, w: f.width, h: f.height)
        guard c.w > 0, c.h > 0, c.x >= 0, c.y >= 0, c.x + c.w <= f.width, c.y + c.h <= f.height,
              f.pixels.count >= f.width * f.height else { return nil }
        var out: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, c.w, c.h, kCVPixelFormatType_OneComponent8,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess, let pb = out else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dst = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        f.pixels.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let s = src.baseAddress else { return }
            for y in 0..<c.h {
                memcpy(dst + y * bpr, s + (c.y + y) * f.width + c.x, c.w)
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
