import Foundation
import Speech
import AVFoundation

/// Apple'ın cihaz içi konuşma tanıması. Ses parça parça (segment) işlenir;
/// her segment bir cümle/duraklamaya kadar sürer, sonra yenisi başlar.
final class AppleRecognizer {
    /// (segment, metin) — ara sonuç
    var onPartial: ((Int, String) -> Void)?
    /// (segment, son metin ya da nil) — segment bitti (hata durumunda metin nil olabilir)
    var onFinal: ((Int, String?) -> Void)?

    private let recognizer: SFSpeechRecognizer
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var finished = Set<Int>()
    private(set) var segment = 0
    private(set) var segmentStartedAt = Date()
    let onDevice: Bool
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!

    init?(localeID: String) {
        guard let r = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else { return nil }
        r.queue = OperationQueue.main
        r.defaultTaskHint = .dictation
        recognizer = r
        onDevice = r.supportsOnDeviceRecognition
    }

    var isAvailable: Bool { recognizer.isAvailable }

    static var isAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }

    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { done(true); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    /// Yeni segment başlatır (öncekini sonlandırmaz).
    func startSegment() {
        segment += 1
        let seg = segment
        segmentStartedAt = Date()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDevice
        req.addsPunctuation = true
        req.taskHint = .dictation
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self = self, !self.finished.contains(seg) else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    self.finished.insert(seg)
                    self.onFinal?(seg, text)
                } else {
                    self.onPartial?(seg, text)
                }
            } else if error != nil {
                self.finished.insert(seg)
                self.onFinal?(seg, nil)
            }
        }
    }

    /// Mevcut segmenti bitirip hemen yenisini başlatır (ses kaybı olmaz).
    func cut() {
        let old = request
        startSegment()
        old?.endAudio()
    }

    func append(_ samples: [Int16]) {
        guard let req = request, !samples.isEmpty,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let ch = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count { ch[i] = Float(samples[i]) / 32768.0 }
        req.append(buf)
    }

    func stop() {
        finished.insert(segment)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}

/// Bulut ses tanıma için sesi 3–7 saniyelik, mümkünse sessiz anlardan bölünen parçalara ayırır.
final class Chunker {
    static let rate = 16000
    private var buf: [Int16] = []
    private var scanFrom = 0
    private let minSamples = Int(3.0 * Double(rate))
    private let maxSamples = Int(7.0 * Double(rate))
    private let window = rate / 10   // 100 ms

    func push(_ samples: [Int16]) -> [[Int16]] {
        buf.append(contentsOf: samples)
        var out: [[Int16]] = []
        while buf.count >= minSamples {
            if scanFrom < minSamples { scanFrom = minSamples }
            let mean = Chunker.rms(buf[0..<minSamples])
            let quiet = max(0.004, mean * 0.35)
            var cut: Int?
            var i = scanFrom
            while i + window <= buf.count && i <= maxSamples {
                if Chunker.rms(buf[i..<(i + window)]) < quiet { cut = i + window / 2; break }
                i += window / 2
            }
            scanFrom = i
            if cut == nil && buf.count >= maxSamples { cut = maxSamples }
            guard let c = cut else { break }
            out.append(Array(buf[0..<c]))
            buf.removeFirst(c)
            scanFrom = 0
        }
        return out
    }

    /// Ses kesildiğinde kalan parçayı verir (çok kısaysa atar).
    func flush(minSeconds: Double) -> [Int16]? {
        defer { buf.removeAll(); scanFrom = 0 }
        guard Double(buf.count) >= minSeconds * Double(Chunker.rate) else { return nil }
        return buf
    }

    static func rms<C: Collection>(_ s: C) -> Float where C.Element == Int16 {
        guard !s.isEmpty else { return 0 }
        var acc: Double = 0
        for v in s { let f = Double(v) / 32768.0; acc += f * f }
        return Float((acc / Double(s.count)).squareRoot())
    }

    /// 16 bit mono WAV dosyası üretir.
    static func wav(_ samples: [Int16], rate: Int = Chunker.rate) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
