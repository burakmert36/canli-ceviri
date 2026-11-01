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
    private var band: (top: Double, bottom: Double) = (0, 1)
    private var languages: [String]?

    /// Okunan satırlar (ana iş parçacığında çağrılır).
    var onResult: (([OCRLine], ScreenFrame) -> Void)?

    func configure(top: Double, bottom: Double, sourceLang: String) {
        lock.lock()
        let t = min(max(top, 0), 0.95)
        band = (t, min(max(bottom, t + 0.05), 1))
        languages = Self.visionLanguages(for: sourceLang)
        lock.unlock()
    }

    /// Kareyi sıraya koyar; önceki kare hâlâ işleniyorsa atlar.
    func submit(_ frame: ScreenFrame) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        let b = band, langs = languages
        lock.unlock()
        queue.async {
            let lines = Self.recognize(frame, band: b, languages: langs)
            self.lock.lock(); self.busy = false; self.lock.unlock()
            DispatchQueue.main.async { self.onResult?(lines, frame) }
        }
    }

    /// Önizleme için tek seferlik okuma (meşguliyetten bağımsız).
    func recognizeOnce(_ frame: ScreenFrame, top: Double, bottom: Double, sourceLang: String,
                       completion: @escaping ([OCRLine]) -> Void) {
        let t = min(max(top, 0), 0.95)
        let b = (t, min(max(bottom, t + 0.05), 1))
        let langs = Self.visionLanguages(for: sourceLang)
        queue.async {
            let lines = Self.recognize(frame, band: b, languages: langs)
            DispatchQueue.main.async { completion(lines) }
        }
    }

    private static func visionLanguages(for source: String) -> [String]? {
        guard source != "auto" else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let lang = source.split(separator: "-").first.map(String.init) ?? source
        if supported.contains(source) { return [source] }
        if let match = supported.first(where: { $0.hasPrefix(lang) }) { return [match] }
        return nil
    }

    private static func recognize(_ f: ScreenFrame, band: (top: Double, bottom: Double), languages: [String]?) -> [OCRLine] {
        guard let pb = makePixelBuffer(f) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.minimumTextHeight = 0.012
        if let l = languages {
            req.recognitionLanguages = l
        } else {
            req.automaticallyDetectsLanguage = true
        }
        // Vision'da y ekseni aşağıdan yukarı: üst sınır → 1 - top
        req.regionOfInterest = CGRect(x: 0, y: 1 - band.bottom, width: 1, height: band.bottom - band.top)
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

/// Okunan satırlardan gerçek altyazıyı ayıklar ve kayan (roll-up) altyazıları tek metinde birleştirir.
final class CaptionTracker {
    private struct Seen { var firstSeen: Date; var lastSeen: Date; var candidate: Bool }
    private var seen: [String: Seen] = [:]
    private var baselinePending = true
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
        return result
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
