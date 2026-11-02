import XCTest
import CoreMedia
@testable import CanliCeviri

/// Yayın uzantısının ses dönüştürücüsü: her biçimden 16 kHz mono'ya.
final class PCMConverterTests: XCTestCase {
    private func run(_ f: SampleFactory.AudioFormat, seconds: Double = 1.0, freq: Double = 440,
                     chunk: Int = 1024, file: StaticString = #filePath, line: UInt = #line) -> [Int16] {
        let conv = PCMConverter(outRate: 16000)
        let total = Int(f.rate * seconds)
        var out = Data()
        var start = 0
        while start < total {
            let n = min(chunk, total - start)
            guard let sb = SampleFactory.audio(f, frames: n, freq: freq, startFrame: start) else {
                XCTFail("örnek oluşturulamadı", file: file, line: line); return []
            }
            if let d = conv.convert(sb) { out.append(d) }
            start += n
        }
        return SampleFactory.int16s(out)
    }

    private func check(_ f: SampleFactory.AudioFormat, file: StaticString = #filePath, line: UInt = #line) {
        let s = run(f, file: file, line: line)
        XCTAssertEqual(Double(s.count), 16000, accuracy: 40, "örnek sayısı", file: file, line: line)
        let body = Array(s.dropFirst(400))
        XCTAssertEqual(SampleFactory.estimateFrequency(body, rate: 16000), 440, accuracy: 12, "frekans", file: file, line: line)
        let peak = body.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThan(peak, 11000, "genlik çok düşük", file: file, line: line)
        XCTAssertLessThan(peak, 20000, "genlik çok yüksek", file: file, line: line)
    }

    func testFloat32Stereo48k() {
        check(.init(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: false))
    }

    func testFloat32StereoNonInterleaved48k() {
        check(.init(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: true))
    }

    func testInt16Mono44k() {
        check(.init(rate: 44100, channels: 1, bits: 16, float: false, bigEndian: false, nonInterleaved: false))
    }

    func testInt16StereoBigEndian44k() {
        // ReplayKit'in uygulama sesi bazen büyük endian gelir.
        check(.init(rate: 44100, channels: 2, bits: 16, float: false, bigEndian: true, nonInterleaved: false))
    }

    func testInt32Stereo48k() {
        check(.init(rate: 48000, channels: 2, bits: 32, float: false, bigEndian: false, nonInterleaved: false))
    }

    func testAlready16kMono() {
        check(.init(rate: 16000, channels: 1, bits: 16, float: false, bigEndian: false, nonInterleaved: false))
    }

    func testOddChunkSizesStayContinuous() {
        // Parça sınırlarında tıkırtı/atlama olmamalı: ardışık örnekler arası fark küçük kalmalı.
        let f = SampleFactory.AudioFormat(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: false)
        let s = run(f, freq: 200, chunk: 333)
        var maxJump = 0
        for i in 1..<s.count { maxJump = max(maxJump, abs(Int(s[i]) - Int(s[i - 1]))) }
        // 200 Hz, 0.5 genlik, 16 kHz: en büyük doğal adım ≈ 2π·200/16000·16383 ≈ 1290
        XCTAssertLessThan(maxJump, 2000)
    }

    func testNaNAndInfinityAreSanitized() {
        let f = SampleFactory.AudioFormat(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: false)
        let conv = PCMConverter(outRate: 16000)
        for v in [Float.nan, .infinity, -.infinity, 1e30, -1e30] {
            guard let sb = SampleFactory.audio(f, frames: 960, freq: 0, overrideValue: v) else { XCTFail(); return }
            let out = conv.convert(sb)
            XCTAssertNotNil(out)
        }
        // Sonrasında normal ses yine doğru çıkmalı (filtre durumu bozulmamalı).
        var out = Data()
        for k in 0..<20 {
            if let sb = SampleFactory.audio(f, frames: 960, freq: 440, startFrame: k * 960), let d = conv.convert(sb) { out.append(d) }
        }
        let s = Array(SampleFactory.int16s(out).dropFirst(1200))
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(SampleFactory.estimateFrequency(s, rate: 16000), 440, accuracy: 20,
                       "NaN sonrası filtre kurtulmalı")
    }

    func testSampleRateChangeMidStream() {
        let conv = PCMConverter(outRate: 16000)
        let a = SampleFactory.AudioFormat(rate: 48000, channels: 2, bits: 32, float: true, bigEndian: false, nonInterleaved: false)
        let b = SampleFactory.AudioFormat(rate: 44100, channels: 1, bits: 16, float: false, bigEndian: false, nonInterleaved: false)
        var total = 0
        for k in 0..<50 {
            let f = k % 2 == 0 ? a : b
            if let sb = SampleFactory.audio(f, frames: 1024, freq: 300, startFrame: k * 1024),
               let d = conv.convert(sb) { total += d.count / 2 }
        }
        let expected = 25.0 * 1024 * 16000 / 48000 + 25.0 * 1024 * 16000 / 44100
        XCTAssertEqual(Double(total), expected, accuracy: 200)
    }

    func testFuzzRandomFormatsNeverCrash() {
        var g = SeededRandom(seed: 7)
        let conv = PCMConverter(outRate: 16000)
        let rates: [Double] = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000, 96000]
        for _ in 0..<300 {
            let bits = [16, 32][g.int(0..<2)]
            let f = SampleFactory.AudioFormat(rate: rates[g.int(0..<rates.count)], channels: g.int(1..<7), bits: bits,
                                              float: bits == 32 && g.int(0..<2) == 0, bigEndian: g.int(0..<2) == 0,
                                              nonInterleaved: g.int(0..<2) == 0)
            guard let sb = SampleFactory.audio(f, frames: g.int(1..<5000), freq: Double(g.int(20..<8000))) else { continue }
            _ = conv.convert(sb)
        }
    }

    func testRMSAndWavHelpers() {
        let silence = [Int16](repeating: 0, count: 1600)
        XCTAssertEqual(Chunker.rms(silence), 0, accuracy: 0.0001)
        let loud = Wire.sine(freq: 440, seconds: 0.1, amplitude: 0.5)
        XCTAssertEqual(Double(Chunker.rms(loud)), 0.5 / 2.0.squareRoot(), accuracy: 0.02)
        let wav = Chunker.wav(loud)
        XCTAssertEqual(wav.count, 44 + loud.count * 2)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
    }

    func testChunkerCutsAtPausesAndCapsLength() {
        let c = Chunker()
        var chunks: [[Int16]] = []
        // 4 sn konuşma + 0,5 sn sessizlik + 9 sn kesintisiz konuşma
        chunks += c.push(Wire.sine(freq: 300, seconds: 4))
        chunks += c.push([Int16](repeating: 0, count: 8000))
        chunks += c.push(Wire.sine(freq: 300, seconds: 9))
        XCTAssertGreaterThanOrEqual(chunks.count, 2)
        for ch in chunks {
            XCTAssertGreaterThanOrEqual(ch.count, 3 * 16000)
            XCTAssertLessThanOrEqual(ch.count, 7 * 16000 + 1600)
        }
    }
}
